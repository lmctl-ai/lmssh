#include "runner.hpp"
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <limits.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <chrono>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

namespace lmssh {
namespace {
bool g_dry = false;
pid_t g_owner = getpid();

const char *tool_name(lmssh_tool t) {
  switch (t) {
    case LMSSH_SSH: return "ssh";
    case LMSSH_SFTP: return "sftp";
    case LMSSH_SCP: return "scp";
    default: return "ssh-keygen";
  }
}

struct Job {
  const Spec *spec = nullptr;
  Outcome *outcome = nullptr;
  pid_t pid = -1;
  int in_fd = -1, out_fd = -1, err_fd = -1;
  size_t written = 0;
  std::chrono::steady_clock::time_point deadline{};
  bool reaped = false;
  bool done() const { return pid < 0 || (reaped && out_fd < 0 && err_fd < 0); }
};

void set_nonblock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }
void close_fd(int &fd) { if (fd >= 0) { close(fd); fd = -1; } }

[[noreturn]] void child_main(const Spec &spec, int in_r, int out_w, int err_w) {
  setsid();  // no controlling tty: ssh cannot prompt on /dev/tty; one group to kill on timeout
  dup2(in_r, 0);
  dup2(out_w, 1);
  dup2(err_w, 2);
  for (int fd = 3; fd < 256; fd++) close(fd);
  for (const auto &kv : spec.env) setenv(kv.first.c_str(), kv.second.c_str(), 1);
  std::vector<std::string> store;
  store.push_back(tool_name(spec.tool));
  for (const auto &a : spec.args) store.push_back(a);
  std::vector<char *> argv;
  for (auto &s : store) argv.push_back(s.data());
  argv.push_back(nullptr);
  int rc = lmssh_run_tool(spec.tool, static_cast<int>(store.size()), argv.data());
  _exit(rc);
}

bool start(Job &job) {
  int in_p[2], out_p[2], err_p[2];
  if (pipe(in_p) != 0) { job.outcome->failure = std::string("pipe: ") + strerror(errno); return false; }
  if (pipe(out_p) != 0) { close(in_p[0]); close(in_p[1]); job.outcome->failure = std::string("pipe: ") + strerror(errno); return false; }
  if (pipe(err_p) != 0) {
    close(in_p[0]); close(in_p[1]); close(out_p[0]); close(out_p[1]);
    job.outcome->failure = std::string("pipe: ") + strerror(errno);
    return false;
  }
  std::cout.flush();
  std::cerr.flush();
  fflush(nullptr);
  pid_t pid = fork();
  if (pid < 0) {
    job.outcome->failure = std::string("fork: ") + strerror(errno);
    for (int fd : {in_p[0], in_p[1], out_p[0], out_p[1], err_p[0], err_p[1]}) close(fd);
    return false;
  }
  if (pid == 0) child_main(*job.spec, in_p[0], out_p[1], err_p[1]);
  close(in_p[0]); close(out_p[1]); close(err_p[1]);
  job.pid = pid;
  job.in_fd = in_p[1]; job.out_fd = out_p[0]; job.err_fd = err_p[0];
  set_nonblock(job.in_fd); set_nonblock(job.out_fd); set_nonblock(job.err_fd);
  if (job.spec->input.empty()) close_fd(job.in_fd);
  if (job.spec->timeout_ms > 0)
    job.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(job.spec->timeout_ms);
  return true;
}

void drain(int &fd, std::string &into) {
  char buf[65536];
  for (;;) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n > 0) { into.append(buf, static_cast<size_t>(n)); continue; }
    if (n == 0 || (errno != EAGAIN && errno != EINTR)) close_fd(fd);
    return;
  }
}

void reap(Job &job, bool block) {
  if (job.reaped) return;
  int st = 0;
  pid_t r = waitpid(job.pid, &st, block ? 0 : WNOHANG);
  if (r != job.pid) return;
  job.reaped = true;
  job.outcome->status = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
}  // namespace

void set_dry_run(bool on) { g_dry = on; }
bool dry_run() { return g_dry; }
bool is_owner() { return getpid() == g_owner; }
void mark_owner() { g_owner = getpid(); }

std::string command_line(const Spec &spec) {
  std::string line = tool_name(spec.tool);
  for (const auto &a : spec.args) {
    bool plain = !a.empty() && a.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_") == std::string::npos;
    line += ' ';
    if (plain) { line += a; continue; }
    line += '\'';
    for (char c : a) { if (c == '\'') line += "'\\''"; else line += c; }
    line += '\'';
  }
  return line;
}

std::vector<Outcome> run_all(const std::vector<Spec> &specs, size_t parallel) {
  std::vector<Outcome> outcomes(specs.size());
  if (g_dry) {
    for (size_t i = 0; i < specs.size(); i++) {
      outcomes[i].status = 0;
      outcomes[i].dry = true;
      std::cerr << "[dry-run] " << command_line(specs[i]) << "\n";
    }
    return outcomes;
  }
  if (parallel < 1) parallel = 1;
  signal(SIGPIPE, SIG_IGN);  // a child that exits early must not kill us mid-write
  std::vector<Job> jobs(specs.size());
  size_t next = 0, active = 0, finished = 0;
  while (finished < specs.size()) {
    while (next < specs.size() && active < parallel) {
      Job &job = jobs[next];
      job.spec = &specs[next];
      job.outcome = &outcomes[next];
      if (!start(job)) finished++; else active++;
      next++;
    }
    std::vector<pollfd> fds;
    std::vector<std::pair<size_t, int>> owner;  // (job index, 0=in 1=out 2=err)
    int wait_ms = 200;
    auto now = std::chrono::steady_clock::now();
    for (size_t i = 0; i < next; i++) {
      Job &job = jobs[i];
      if (job.pid < 0 || job.done()) continue;
      if (job.in_fd >= 0) { fds.push_back({job.in_fd, POLLOUT, 0}); owner.push_back({i, 0}); }
      if (job.out_fd >= 0) { fds.push_back({job.out_fd, POLLIN, 0}); owner.push_back({i, 1}); }
      if (job.err_fd >= 0) { fds.push_back({job.err_fd, POLLIN, 0}); owner.push_back({i, 2}); }
      if (job.spec->timeout_ms > 0 && !job.outcome->timed_out) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(job.deadline - now).count();
        if (left < 0) left = 0;
        if (left < wait_ms) wait_ms = static_cast<int>(left);
      }
    }
    if (!fds.empty()) poll(fds.data(), fds.size(), wait_ms);
    else usleep(10000);
    for (size_t k = 0; k < fds.size(); k++) {
      if (!fds[k].revents) continue;
      Job &job = jobs[owner[k].first];
      switch (owner[k].second) {
        case 0: {
          const std::string &in = job.spec->input;
          ssize_t n = write(job.in_fd, in.data() + job.written, in.size() - job.written);
          if (n > 0) job.written += static_cast<size_t>(n);
          if ((n < 0 && errno != EAGAIN && errno != EINTR) || job.written >= in.size()) close_fd(job.in_fd);
          break;
        }
        case 1: drain(job.out_fd, job.outcome->out); break;
        default: drain(job.err_fd, job.outcome->err); break;
      }
    }
    now = std::chrono::steady_clock::now();
    for (size_t i = 0; i < next; i++) {
      Job &job = jobs[i];
      if (job.pid < 0 || job.done()) continue;
      if (job.spec->timeout_ms > 0 && !job.outcome->timed_out && !job.reaped && now >= job.deadline) {
        job.outcome->timed_out = true;
        kill(-job.pid, SIGKILL);
        kill(job.pid, SIGKILL);
        // Grandchildren (a ControlPersist master) may keep the pipes open: stop waiting on them.
        close_fd(job.out_fd);
        close_fd(job.err_fd);
      }
      reap(job, false);
      if (job.reaped && (job.out_fd >= 0 || job.err_fd >= 0)) {
        // The child is gone; collect what is buffered, but do not wait for stray holders of the pipe.
        if (job.out_fd >= 0) drain(job.out_fd, job.outcome->out);
        if (job.err_fd >= 0) drain(job.err_fd, job.outcome->err);
        if (!job.outcome->timed_out) {
          pollfd p[2] = {{job.out_fd, POLLIN, 0}, {job.err_fd, POLLIN, 0}};
          if (poll(p, 2, 0) == 0) { close_fd(job.out_fd); close_fd(job.err_fd); }
        }
      }
      if (job.done()) {
        close_fd(job.in_fd);
        if (job.outcome->timed_out) job.outcome->status = 124;
        finished++;
        active--;
        job.pid = -1;
      }
    }
  }
  return outcomes;
}

Outcome run_one(const Spec &spec) { return run_all({spec}, 1)[0]; }

std::string self_executable(const char *argv0) {
  char buf[PATH_MAX];
#ifdef __APPLE__
  uint32_t size = sizeof buf;
  char raw[PATH_MAX];
  if (_NSGetExecutablePath(raw, &size) == 0 && realpath(raw, buf)) return buf;
#else
  ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
  if (n > 0) { buf[n] = 0; return buf; }
#endif
  if (argv0 && strchr(argv0, '/') && realpath(argv0, buf)) return buf;
  if (argv0) {
    const char *path = getenv("PATH");
    std::string p = path ? path : "";
    size_t pos = 0;
    while (pos <= p.size()) {
      size_t e = p.find(':', pos);
      if (e == std::string::npos) e = p.size();
      std::string cand = p.substr(pos, e - pos) + "/" + argv0;
      if (access(cand.c_str(), X_OK) == 0 && realpath(cand.c_str(), buf)) return buf;
      pos = e + 1;
    }
  }
  return argv0 ? argv0 : "lmssh";
}

}  // namespace lmssh
