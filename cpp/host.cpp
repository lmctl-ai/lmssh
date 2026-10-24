#include "host.hpp"
#include "stdlib/string.hpp"
#include <algorithm>
#include <openssl/evp.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace lmssh {
namespace {
using dslvm::Args;
using dslvm::Value;
namespace fs = std::filesystem;

template <class T> T *self(void *p) { return static_cast<T *>(p); }

std::string trim(const std::string &s) {
  size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
  return b == std::string::npos ? "" : s.substr(b, e - b + 1);
}

std::string first_line(const std::string &s) {
  std::string t = trim(s);
  return t.substr(0, t.find('\n'));
}

std::vector<std::string> split_lines(const std::string &s) {
  std::vector<std::string> out;
  std::istringstream in(s);
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    out.push_back(line);
  }
  return out;
}

std::string read_whole(const std::string &path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw dslvm::Error("cannot read " + path + ": " + strerror(errno));
  std::ostringstream buf;
  buf << in.rdbuf();
  return buf.str();
}

void write_whole(const std::string &path, const std::string &data, bool append = false) {
  if (dry_run()) { std::cerr << "[dry-run] write " << path << " (" << data.size() << " bytes)\n"; return; }
  std::ofstream out(path, std::ios::binary | (append ? std::ios::app : std::ios::trunc));
  if (!out) throw dslvm::Error("cannot write " + path + ": " + strerror(errno));
  out << data;
  if (!out) throw dslvm::Error("failed writing " + path);
}

// ---- argument assembly -------------------------------------------------------------------------

std::string with_user(const std::string &dest, const Options &o) {
  return o.user.empty() || dest.find('@') != std::string::npos ? dest : o.user + "@" + dest;
}

// ssh, sftp and scp share -o/-i/-F/-J; the port flag is -p for ssh and -P for the others.
std::vector<std::string> common_args(Host &h, const Options &o, lmssh_tool tool) {
  std::vector<std::string> a;
  if (!o.config.empty()) { a.push_back("-F"); a.push_back(o.config); }
  if (o.password.empty()) a.insert(a.end(), {"-o", "BatchMode=yes"});
  else a.insert(a.end(), {"-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"});
  if (o.connect_timeout > 0) a.insert(a.end(), {"-o", "ConnectTimeout=" + std::to_string(o.connect_timeout)});
  if (!o.strict_host_key.empty()) a.insert(a.end(), {"-o", "StrictHostKeyChecking=" + o.strict_host_key});
  if (!o.known_hosts.empty()) a.insert(a.end(), {"-o", "UserKnownHostsFile=" + o.known_hosts});
  if (!o.identities.empty()) a.insert(a.end(), {"-o", "IdentitiesOnly=yes"});
  for (const auto &id : o.identities) { a.push_back("-i"); a.push_back(id); }
  if (!o.jump.empty()) { a.push_back("-J"); a.push_back(o.jump); }
  if (o.port > 0) { a.push_back(tool == LMSSH_SSH ? "-p" : "-P"); a.push_back(std::to_string(o.port)); }
  if (o.reuse) {
    a.insert(a.end(), {"-o", "ControlMaster=auto", "-o", "ControlPath=" + h.work() + "/c-%C", "-o", "ControlPersist=120"});
  }
  for (const auto &r : o.raw) { a.push_back("-o"); a.push_back(r); }
  return a;
}

Spec make_spec(Host &h, const Options &o, lmssh_tool tool, std::vector<std::string> args) {
  Spec s;
  s.tool = tool;
  s.args = common_args(h, o, tool);
  s.args.insert(s.args.end(), args.begin(), args.end());
  s.timeout_ms = o.timeout * 1000;
  if (!o.password.empty()) {
    // The linked ssh asks for secrets through SSH_ASKPASS; this very executable answers (cpp/main.cpp).
    s.env.push_back({"SSH_ASKPASS", lmssh_get_self()});
    s.env.push_back({"SSH_ASKPASS_REQUIRE", "force"});
    s.env.push_back({"LMSSH_ASKPASS_SECRET", o.password});
    if (!getenv("DISPLAY")) s.env.push_back({"DISPLAY", "lmssh:0"});
  }
  return s;
}

std::string scp_host(const std::string &dest) {
  // scp needs [v6] brackets for a literal address, ssh does not.
  auto at = dest.find('@');
  std::string user = at == std::string::npos ? "" : dest.substr(0, at + 1);
  std::string host = at == std::string::npos ? dest : dest.substr(at + 1);
  if (host.find(':') != std::string::npos && host.front() != '[') host = "[" + host + "]";
  return user + host;
}

std::string sftp_quote(const std::string &path) {
  std::string q = "\"";
  for (char c : path) {
    if (c == '"' || c == '\\') q += '\\';
    q += c;
  }
  return q + "\"";
}

std::string describe(const Result &r) {
  std::string why = r.outcome.timed_out ? "timed out" : "exited " + std::to_string(r.outcome.status);
  std::string detail = first_line(r.outcome.err);
  if (detail.empty()) detail = first_line(r.outcome.out);
  return r.dest + ": " + r.command + " " + why + (detail.empty() ? "" : ": " + detail);
}

bool succeeded(const Outcome &o) { return o.dry || (o.status == 0 && !o.timed_out && o.failure.empty()); }

Result run_result(Host &h, const std::string &dest, Spec spec) {
  (void)h;
  Result r;
  r.dest = dest;
  r.command = command_line(spec);
  // Never leak a secret into messages: only the env carries it, the command line does not.
  r.outcome = run_one(spec);
  if (!r.outcome.failure.empty()) throw dslvm::Error(dest + ": cannot start " + r.command + ": " + r.outcome.failure);
  return r;
}

void require_ok(const Result &r) {
  if (!succeeded(r.outcome)) throw dslvm::Error(describe(r));
}

Value hold_result(Host &h, Result r) {
  if (h.results.size() >= 65536) throw dslvm::Error("Result object limit exceeded (65536)");
  h.results.push_back(std::move(r));
  return Value::object("Result", &h.results.back());
}

Value hold_strs(Host &h, std::vector<std::string> v) {
  return Value::object("StrList", h.collections.make_str_list(std::move(v)));
}

// ---- sessions ------------------------------------------------------------------------------------

Result exec_on(Host &h, const std::string &dest, const Options &o, const std::string &cmd, const std::string &input) {
  Spec s = make_spec(h, o, LMSSH_SSH, {with_user(dest, o), cmd});
  s.input = input;
  return run_result(h, dest, s);
}

Result sftp_on(Host &h, const std::string &dest, const Options &o, const std::string &batch) {
  Spec s = make_spec(h, o, LMSSH_SFTP, {"-b", "-", with_user(dest, o)});
  s.input = batch;
  return run_result(h, dest, s);
}

Result scp_on(Host &h, const Session &s, bool recursive, const std::string &from, const std::string &to) {
  Spec spec = make_spec(h, s.opts, LMSSH_SCP, {});
  spec.args.push_back("-q");
  if (recursive) spec.args.push_back("-r");
  spec.args.push_back("--");
  spec.args.push_back(from);
  spec.args.push_back(to);
  return run_result(h, s.dest, spec);
}

std::string remote_spec(const Session &s, const std::string &path) {
  return scp_host(with_user(s.dest, s.opts)) + ":" + path;
}

void close_master(Host &h, const std::string &dest, const Options &o) {
  Options quiet = o;
  quiet.password.clear();
  Spec s = make_spec(h, quiet, LMSSH_SSH, {"-O", "exit", with_user(dest, o)});
  s.timeout_ms = 10000;
  run_one(s);
}

// Setters shared by the Ssh defaults and by each Session.
template <class OptsOf>
void register_option_setters(dslvm::Registry &r, const char *type, OptsOf of);

}  // namespace

// ---- Host ----------------------------------------------------------------------------------------

Host::Host() : owner(getpid()) { mark_owner(); }

Host::~Host() { shutdown(); }

const std::string &Host::work() {
  if (work_dir.empty()) {
    char tpl[] = "/tmp/lmssh-XXXXXX";  // short on purpose: unix socket paths are limited to ~104 bytes
    if (!mkdtemp(tpl)) throw dslvm::Error(std::string("cannot create a private work directory: ") + strerror(errno));
    work_dir = tpl;
  }
  return work_dir;
}

void Host::shutdown() {
  if (!is_owner() || work_dir.empty()) return;
  if (!dry_run()) {
    std::error_code ec;
    for (const auto &entry : fs::directory_iterator(work_dir, ec)) {
      std::string name = entry.path().filename().string();
      if (name.rfind("c-", 0) != 0) continue;
      Spec s;
      s.tool = LMSSH_SSH;
      s.args = {"-o", "ControlPath=" + entry.path().string(), "-O", "exit", "lmssh"};
      s.timeout_ms = 10000;
      run_one(s);
    }
  }
  std::error_code ec;
  fs::remove_all(work_dir, ec);
  work_dir.clear();
}

namespace {

template <class OptsOf>
void register_option_setters(dslvm::Registry &r, const char *type, OptsOf of) {
  std::string t = type;
  auto self_value = [t](void *p) { return Value::object(t, p); };
  r.method(type, "port", {"int"}, type, [of, self_value](void *p, Args &a) {
    if (a[0].i < 0 || a[0].i > 65535) throw dslvm::Error("port out of range: " + std::to_string(a[0].i));
    of(p).port = static_cast<int>(a[0].i);
    return self_value(p);
  });
  auto text = [&](const char *name, std::string Options::*field) {
    r.method(type, name, {"string"}, type, [of, field, self_value](void *p, Args &a) {
      of(p).*field = a[0].s;
      return self_value(p);
    });
  };
  text("user", &Options::user);
  text("known_hosts", &Options::known_hosts);
  text("config", &Options::config);
  text("jump", &Options::jump);
  text("strict_host_key", &Options::strict_host_key);
  text("password", &Options::password);
  r.method(type, "identity", {"string"}, type, [of, self_value](void *p, Args &a) {
    of(p).identities.push_back(a[0].s);
    return self_value(p);
  });
  r.method(type, "option", {"string"}, type, [of, self_value](void *p, Args &a) {
    if (a[0].s.find('=') == std::string::npos) throw dslvm::Error("option expects Key=Value, got: " + a[0].s);
    of(p).raw.push_back(a[0].s);
    return self_value(p);
  });
  r.method(type, "connect_timeout", {"int"}, type, [of, self_value](void *p, Args &a) {
    of(p).connect_timeout = static_cast<int>(std::max<int64_t>(0, a[0].i));
    return self_value(p);
  });
  r.method(type, "timeout", {"int"}, type, [of, self_value](void *p, Args &a) {
    of(p).timeout = static_cast<int>(std::max<int64_t>(0, a[0].i));
    return self_value(p);
  });
  r.method(type, "reuse", {"bool"}, type, [of, self_value](void *p, Args &a) {
    of(p).reuse = a[0].b;
    return self_value(p);
  });
  r.method(type, "parallel", {"int"}, type, [of, self_value](void *p, Args &a) {
    of(p).parallel = static_cast<int>(std::clamp<int64_t>(a[0].i, 1, 256));
    return self_value(p);
  });
}

void check_args(const std::string &where, const std::vector<std::string> &params, Args &args) {
  for (size_t i = 0; i < params.size(); i++) {
    const auto &want = params[i];
    const auto &v = args[i];
    bool ok = want == "float" ? v.kind == Value::FLOAT
              : want == "int" ? v.kind == Value::INT
              : want == "string" ? v.kind == Value::STR
              : want == "bool" ? v.kind == Value::BOOL
              : v.kind == Value::OBJ && v.type == want && v.obj;
    if (!ok) throw dslvm::Error(where + " argument " + std::to_string(i + 1) + " must be " + want);
  }
}

template <class F> Value translate(F &&fn) {
  try {
    return fn();
  } catch (const dslvm::Error &) {
    throw;
  } catch (const std::string &e) {
    throw dslvm::Error(e);
  } catch (const std::exception &e) {
    throw dslvm::Error(e.what());
  }
}

void method(dslvm::Registry &r, const char *type, const char *name, std::vector<std::string> params,
            std::string returns, dslvm::Method fn) {
  std::string where = std::string(type) + "." + name;
  r.method(type, name, params, returns, [params, fn, where](void *self_, Args &args) {
    check_args(where, params, args);
    return translate([&] { return fn(self_, args); });
  });
}

void function(dslvm::Registry &r, const char *name, std::vector<std::string> params, std::string returns,
              dslvm::Function fn) {
  std::string where = name;
  r.function(name, params, returns, [params, fn, where](Args &args) {
    check_args(where, params, args);
    return translate([&] { return fn(args); });
  });
}

// ---- ssh-keygen helpers ----------------------------------------------------------------------------

Result keygen(Host &h, std::vector<std::string> args, bool must_succeed = true, const std::string &input = "") {
  Spec s;
  s.tool = LMSSH_KEYGEN;
  s.args = std::move(args);
  s.input = input;
  s.timeout_ms = 120000;
  Result r = run_result(h, "ssh-keygen", s);
  if (must_succeed) require_ok(r);
  return r;
}

struct Fingerprint { std::string bits, hash, comment, type; };

Fingerprint fingerprint_of(Host &h, const std::string &path) {
  if (dry_run()) return {"0", "SHA256:dry-run", "", "dry-run"};
  Result r = keygen(h, {"-l", "-f", path});
  std::string line = first_line(r.outcome.out);
  Fingerprint f;
  size_t a = line.find(' '), b = a == std::string::npos ? a : line.find(' ', a + 1);
  if (a == std::string::npos || b == std::string::npos) throw dslvm::Error("cannot parse ssh-keygen -l output for " + path + ": " + line);
  f.bits = line.substr(0, a);
  f.hash = line.substr(a + 1, b - a - 1);
  size_t paren = line.rfind(" (");
  if (paren != std::string::npos && line.back() == ')') {
    f.type = line.substr(paren + 2, line.size() - paren - 3);
    f.comment = paren > b ? line.substr(b + 1, paren - b - 1) : "";
  } else {
    f.comment = line.substr(b + 1);
  }
  std::transform(f.type.begin(), f.type.end(), f.type.begin(), [](unsigned char c) { return std::tolower(c); });
  return f;
}

std::string public_of(Host &h, const std::string &path, const std::string &passphrase) {
  if (fs::exists(path + ".pub")) return trim(read_whole(path + ".pub"));
  Result r = keygen(h, {"-y", "-P", passphrase, "-f", path});
  return trim(r.outcome.out);
}

std::string json_text(const std::string &s) { return dslvm::json_escape(s); }

std::string text_escape(const std::string &s) {
  std::string out;
  for (unsigned char c : s) {
    if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else if (c < 0x20 || c == 0x7f) { char b[8]; std::snprintf(b, sizeof b, "\\x%02x", c); out += b; }
    else out += static_cast<char>(c);
  }
  return out;
}

std::string report_text(const Report &report) {
  std::string out;
  for (const auto &f : report.findings)
    out += text_escape(f.kind) + " " + text_escape(f.file) + ":" + std::to_string(f.line) + ": " + text_escape(f.message) + "\n";
  return out;
}

}  // namespace

void register_host(dslvm::Registry &r, Host &h) {
  r.context("ssh", "Ssh");
  r.context("keys", "Keys");
  r.context("io", "Io");
  r.context("report", "Report");
  dslvm::stdlib::register_string(r);
  dslvm::stdlib::register_collections(r, h.collections);

  auto defaults_of = [](void *p) -> Options & { return *self<Options>(p); };
  auto session_of = [](void *p) -> Options & { return self<Session>(p)->opts; };
  register_option_setters(r, "Ssh", defaults_of);
  register_option_setters(r, "Session", session_of);

  // ---- Ssh ----
  method(r, "Ssh", "connect", {"string"}, "Session", [&h](void *, Args &a) {
    if (a[0].s.empty() || a[0].s[0] == '-') throw dslvm::Error("Ssh.connect: invalid destination: " + a[0].s);
    if (h.sessions.size() >= 65536) throw dslvm::Error("Session object limit exceeded (65536)");
    h.sessions.push_back(Session{a[0].s, h.defaults});
    return Value::object("Session", &h.sessions.back());
  });
  method(r, "Ssh", "each", {"StrList", "string"}, "ResultList", [&h](void *, Args &a) {
    auto *dests = self<StrList>(a[0].obj);
    std::vector<Spec> specs;
    for (const auto &d : dests->items) {
      if (d.empty() || d[0] == '-') throw dslvm::Error("Ssh.each: invalid destination: " + d);
      specs.push_back(make_spec(h, h.defaults, LMSSH_SSH, {with_user(d, h.defaults), a[1].s}));
    }
    auto outcomes = run_all(specs, static_cast<size_t>(h.defaults.parallel));
    ResultList list;
    for (size_t i = 0; i < specs.size(); i++) {
      Result res;
      res.dest = dests->items[i];
      res.command = command_line(specs[i]);
      res.outcome = std::move(outcomes[i]);
      if (!res.outcome.failure.empty()) throw dslvm::Error(res.dest + ": cannot start: " + res.outcome.failure);
      h.results.push_back(std::move(res));
      list.items.push_back(&h.results.back());
    }
    h.result_lists.push_back(std::move(list));
    return Value::object("ResultList", &h.result_lists.back());
  });
  method(r, "Ssh", "shutdown", {}, "void", [&h](void *, Args &) {
    h.shutdown();
    return Value::none();
  });

  // ---- Session ----
  method(r, "Session", "dest", {}, "string", [](void *p, Args &) { return Value::string(self<Session>(p)->dest); });
  method(r, "Session", "exec", {"string"}, "Result", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    return hold_result(h, exec_on(h, s->dest, s->opts, a[0].s, ""));
  });
  method(r, "Session", "exec", {"string", "string"}, "Result", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    return hold_result(h, exec_on(h, s->dest, s->opts, a[0].s, a[1].s));
  });
  method(r, "Session", "output", {"string"}, "string", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    Result res = exec_on(h, s->dest, s->opts, a[0].s, "");
    require_ok(res);
    return Value::string(res.outcome.out);
  });
  method(r, "Session", "ok", {"string"}, "bool", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    return Value::boolean(succeeded(exec_on(h, s->dest, s->opts, a[0].s, "").outcome));
  });
  method(r, "Session", "put", {"string", "string"}, "void", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    if (!dry_run() && !fs::is_regular_file(a[0].s)) throw dslvm::Error("Session.put: not a file: " + a[0].s);
    require_ok(scp_on(h, *s, false, a[0].s, remote_spec(*s, a[1].s)));
    return Value::none();
  });
  method(r, "Session", "get", {"string", "string"}, "void", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    require_ok(scp_on(h, *s, false, remote_spec(*s, a[0].s), a[1].s));
    return Value::none();
  });
  method(r, "Session", "put_dir", {"string", "string"}, "void", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    if (!dry_run() && !fs::is_directory(a[0].s)) throw dslvm::Error("Session.put_dir: not a directory: " + a[0].s);
    require_ok(scp_on(h, *s, true, a[0].s, remote_spec(*s, a[1].s)));
    return Value::none();
  });
  method(r, "Session", "get_dir", {"string", "string"}, "void", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    require_ok(scp_on(h, *s, true, remote_spec(*s, a[0].s), a[1].s));
    return Value::none();
  });
  method(r, "Session", "cat", {"string"}, "string", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    std::string tmp = h.work() + "/cat-" + std::to_string(h.results.size()) + "-" + std::to_string(getpid());
    require_ok(scp_on(h, *s, false, remote_spec(*s, a[0].s), tmp));
    if (dry_run()) return Value::string("");
    std::string data = read_whole(tmp);
    unlink(tmp.c_str());
    return Value::string(data);
  });
  method(r, "Session", "write", {"string", "string"}, "void", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    std::string tmp = h.work() + "/put-" + std::to_string(h.results.size()) + "-" + std::to_string(getpid());
    write_whole(tmp, a[1].s);
    Result res = scp_on(h, *s, false, tmp, remote_spec(*s, a[0].s));
    unlink(tmp.c_str());
    require_ok(res);
    return Value::none();
  });
  method(r, "Session", "sftp", {"string"}, "Result", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    Result res = sftp_on(h, s->dest, s->opts, a[0].s);
    // Batch mode echoes each command as "sftp> ...": keep only the commands' own output.
    std::string clean;
    for (const auto &line : split_lines(res.outcome.out))
      if (line.rfind("sftp> ", 0) != 0) clean += line + "\n";
    res.outcome.out = clean;
    return hold_result(h, std::move(res));
  });
  auto sftp_ok = [&h](Session *s, const std::string &batch) {
    Result res = sftp_on(h, s->dest, s->opts, batch);
    require_ok(res);
    return res;
  };
  method(r, "Session", "ls", {"string"}, "StrList", [&h, sftp_ok](void *p, Args &a) {
    Result res = sftp_ok(self<Session>(p), "ls -1 " + sftp_quote(a[0].s) + "\n");
    std::vector<std::string> names;
    for (const auto &line : split_lines(res.outcome.out)) {
      if (line.empty() || line.rfind("sftp> ", 0) == 0) continue;
      auto slash = line.find_last_of('/');
      names.push_back(slash == std::string::npos ? line : line.substr(slash + 1));
    }
    return hold_strs(h, std::move(names));
  });
  method(r, "Session", "exists", {"string"}, "bool", [&h](void *p, Args &a) {
    auto *s = self<Session>(p);
    return Value::boolean(succeeded(sftp_on(h, s->dest, s->opts, "ls -1 " + sftp_quote(a[0].s) + "\n").outcome));
  });
  method(r, "Session", "mkdir", {"string"}, "void", [sftp_ok](void *p, Args &a) {
    sftp_ok(self<Session>(p), "mkdir " + sftp_quote(a[0].s) + "\n");
    return Value::none();
  });
  method(r, "Session", "rm", {"string"}, "void", [sftp_ok](void *p, Args &a) {
    sftp_ok(self<Session>(p), "rm " + sftp_quote(a[0].s) + "\n");
    return Value::none();
  });
  method(r, "Session", "rmdir", {"string"}, "void", [sftp_ok](void *p, Args &a) {
    sftp_ok(self<Session>(p), "rmdir " + sftp_quote(a[0].s) + "\n");
    return Value::none();
  });
  method(r, "Session", "rename", {"string", "string"}, "void", [sftp_ok](void *p, Args &a) {
    sftp_ok(self<Session>(p), "rename " + sftp_quote(a[0].s) + " " + sftp_quote(a[1].s) + "\n");
    return Value::none();
  });
  method(r, "Session", "close", {}, "void", [&h](void *p, Args &) {
    auto *s = self<Session>(p);
    if (s->opts.reuse) close_master(h, s->dest, s->opts);
    return Value::none();
  });

  // ---- Result / ResultList ----
  method(r, "Result", "ok", {}, "bool", [](void *p, Args &) { return Value::boolean(succeeded(self<Result>(p)->outcome)); });
  method(r, "Result", "status", {}, "int", [](void *p, Args &) { return Value::integer(self<Result>(p)->outcome.status); });
  method(r, "Result", "stdout", {}, "string", [](void *p, Args &) { return Value::string(self<Result>(p)->outcome.out); });
  method(r, "Result", "stderr", {}, "string", [](void *p, Args &) { return Value::string(self<Result>(p)->outcome.err); });
  method(r, "Result", "dest", {}, "string", [](void *p, Args &) { return Value::string(self<Result>(p)->dest); });
  method(r, "Result", "timed_out", {}, "bool", [](void *p, Args &) { return Value::boolean(self<Result>(p)->outcome.timed_out); });
  method(r, "Result", "require", {}, "Result", [](void *p, Args &) {
    require_ok(*self<Result>(p));
    return Value::object("Result", p);
  });
  method(r, "ResultList", "len", {}, "int", [](void *p, Args &) { return Value::integer(static_cast<int64_t>(self<ResultList>(p)->items.size())); });
  method(r, "ResultList", "at", {"int"}, "Result", [](void *p, Args &a) {
    auto *l = self<ResultList>(p);
    if (a[0].i < 0 || static_cast<size_t>(a[0].i) >= l->items.size()) throw dslvm::Error("ResultList.at: index out of range: " + std::to_string(a[0].i));
    return Value::object("Result", l->items[static_cast<size_t>(a[0].i)]);
  });
  method(r, "ResultList", "failed", {}, "int", [](void *p, Args &) {
    int64_t n = 0;
    for (auto *res : self<ResultList>(p)->items) if (!succeeded(res->outcome)) n++;
    return Value::integer(n);
  });
  method(r, "ResultList", "require_all", {}, "ResultList", [](void *p, Args &) {
    std::string msg;
    int n = 0;
    for (auto *res : self<ResultList>(p)->items)
      if (!succeeded(res->outcome)) { msg += (n++ ? "; " : "") + describe(*res); }
    if (n) throw dslvm::Error(std::to_string(n) + " failed: " + msg);
    return Value::object("ResultList", p);
  });

  // ---- Keys ----
  auto hold_key = [&h](const std::string &path) {
    h.keys.push_back(Key{path});
    return Value::object("Key", &h.keys.back());
  };
  method(r, "Keys", "bits", {"int"}, "Keys", [&h](void *p, Args &a) {
    h.key_bits = static_cast<int>(std::max<int64_t>(0, a[0].i));
    return Value::object("Keys", p);
  });
  auto generate = [&h, hold_key](const std::string &path, const std::string &type, const std::string &comment,
                                 const std::string &passphrase) {
    if (fs::exists(path) || fs::exists(path + ".pub")) throw dslvm::Error("Keys.generate: refusing to overwrite " + path);
    std::vector<std::string> args = {"-q", "-t", type, "-f", path, "-N", passphrase, "-C", comment};
    if (h.key_bits > 0) { args.push_back("-b"); args.push_back(std::to_string(h.key_bits)); }
    keygen(h, args);
    return hold_key(path);
  };
  method(r, "Keys", "generate", {"string", "string"}, "Key", [generate](void *, Args &a) { return generate(a[0].s, a[1].s, "", ""); });
  method(r, "Keys", "generate", {"string", "string", "string", "string"}, "Key", [generate](void *, Args &a) {
    return generate(a[0].s, a[1].s, a[2].s, a[3].s);
  });
  method(r, "Keys", "load", {"string"}, "Key", [hold_key](void *, Args &a) {
    if (!dry_run() && !fs::exists(a[0].s)) throw dslvm::Error("Keys.load: no such file: " + a[0].s);
    return hold_key(a[0].s);
  });
  method(r, "Keys", "fingerprint", {"string"}, "string", [&h](void *, Args &a) { return Value::string(fingerprint_of(h, a[0].s).hash); });
  method(r, "Keys", "change_passphrase", {"string", "string", "string"}, "void", [&h](void *, Args &a) {
    keygen(h, {"-q", "-p", "-f", a[0].s, "-P", a[1].s, "-N", a[2].s});
    return Value::none();
  });
  method(r, "Keys", "set_comment", {"string", "string", "string"}, "void", [&h](void *, Args &a) {
    keygen(h, {"-q", "-c", "-f", a[0].s, "-P", a[2].s, "-C", a[1].s});
    return Value::none();
  });
  method(r, "Keys", "known_hosts_find", {"string", "string"}, "string", [&h](void *, Args &a) {
    Result res = keygen(h, {"-F", a[0].s, "-f", a[1].s}, false);
    return Value::string(res.outcome.out);
  });
  method(r, "Keys", "known_hosts_remove", {"string", "string"}, "void", [&h](void *, Args &a) {
    keygen(h, {"-q", "-R", a[0].s, "-f", a[1].s}, false);
    return Value::none();
  });
  method(r, "Keys", "known_hosts_hash", {"string"}, "void", [&h](void *, Args &a) {
    keygen(h, {"-q", "-H", "-f", a[0].s});
    return Value::none();
  });
  method(r, "Keys", "certify", {"string", "string", "string", "string", "string"}, "string", [&h](void *, Args &a) {
    // ca_key, public_key, identity, principals (comma separated), validity (ssh-keygen -V, e.g. "+52w")
    keygen(h, {"-q", "-s", a[0].s, "-I", a[2].s, "-n", a[3].s, "-V", a[4].s, a[1].s});
    std::string cert = a[1].s;
    if (cert.size() > 4 && cert.compare(cert.size() - 4, 4, ".pub") == 0) cert.resize(cert.size() - 4);
    return Value::string(cert + "-cert.pub");
  });
  method(r, "Keys", "sign", {"string", "string", "string"}, "string", [&h](void *, Args &a) {
    keygen(h, {"-q", "-Y", "sign", "-f", a[0].s, "-n", a[1].s, a[2].s});
    return Value::string(a[2].s + ".sig");
  });
  method(r, "Keys", "verify", {"string", "string", "string", "string", "string"}, "bool", [&h](void *, Args &a) {
    // allowed_signers, identity, namespace, signature file, data file
    if (!dry_run() && !fs::exists(a[4].s)) throw dslvm::Error("Keys.verify: no such file: " + a[4].s);
    Result res = keygen(h, {"-Y", "verify", "-f", a[0].s, "-I", a[1].s, "-n", a[2].s, "-s", a[3].s}, false, read_whole(a[4].s));
    return Value::boolean(succeeded(res.outcome));
  });
  method(r, "Key", "path", {}, "string", [](void *p, Args &) { return Value::string(self<Key>(p)->path); });
  method(r, "Key", "public", {}, "string", [&h](void *p, Args &) {
    return Value::string(public_of(h, self<Key>(p)->path, ""));
  });
  method(r, "Key", "public_with", {"string"}, "string", [&h](void *p, Args &a) {
    return Value::string(public_of(h, self<Key>(p)->path, a[0].s));
  });
  method(r, "Key", "fingerprint", {}, "string", [&h](void *p, Args &) { return Value::string(fingerprint_of(h, self<Key>(p)->path).hash); });
  method(r, "Key", "type", {}, "string", [&h](void *p, Args &) { return Value::string(fingerprint_of(h, self<Key>(p)->path).type); });
  method(r, "Key", "comment", {}, "string", [&h](void *p, Args &) { return Value::string(fingerprint_of(h, self<Key>(p)->path).comment); });
  method(r, "Key", "bits", {}, "int", [&h](void *p, Args &) {
    return Value::integer(std::atoll(fingerprint_of(h, self<Key>(p)->path).bits.c_str()));
  });

  // ---- Io ----
  method(r, "Io", "print", {"string"}, "void", [](void *, Args &a) { std::cout << a[0].s << "\n"; return Value::none(); });
  method(r, "Io", "eprint", {"string"}, "void", [](void *, Args &a) { std::cerr << a[0].s << "\n"; return Value::none(); });
  method(r, "Io", "read", {"string"}, "string", [](void *, Args &a) { return Value::string(read_whole(a[0].s)); });
  method(r, "Io", "lines", {"string"}, "StrList", [&h](void *, Args &a) { return hold_strs(h, split_lines(read_whole(a[0].s))); });
  method(r, "Io", "write", {"string", "string"}, "void", [](void *, Args &a) { write_whole(a[0].s, a[1].s); return Value::none(); });
  method(r, "Io", "append", {"string", "string"}, "void", [](void *, Args &a) { write_whole(a[0].s, a[1].s, true); return Value::none(); });
  method(r, "Io", "exists", {"string"}, "bool", [](void *, Args &a) {
    std::error_code ec;
    return Value::boolean(fs::exists(a[0].s, ec));
  });
  method(r, "Io", "mkdir", {"string"}, "void", [](void *, Args &a) {
    if (dry_run()) { std::cerr << "[dry-run] mkdir " << a[0].s << "\n"; return Value::none(); }
    std::error_code ec;
    fs::create_directories(a[0].s, ec);
    if (ec) throw dslvm::Error("Io.mkdir " + a[0].s + ": " + ec.message());
    return Value::none();
  });
  method(r, "Io", "remove", {"string"}, "void", [](void *, Args &a) {
    if (dry_run()) { std::cerr << "[dry-run] remove " << a[0].s << "\n"; return Value::none(); }
    std::error_code ec;
    fs::remove_all(a[0].s, ec);
    if (ec) throw dslvm::Error("Io.remove " + a[0].s + ": " + ec.message());
    return Value::none();
  });
  method(r, "Io", "env", {"string"}, "string", [](void *, Args &a) {
    const char *v = getenv(a[0].s.c_str());
    return Value::string(v ? v : "");
  });
  method(r, "Io", "args", {}, "StrList", [&h](void *, Args &) { return hold_strs(h, h.script_args); });
  method(r, "Io", "temp_dir", {}, "string", [&h](void *, Args &) { return Value::string(h.work()); });
  method(r, "Io", "sleep_ms", {"int"}, "void", [](void *, Args &a) {
    if (!dry_run() && a[0].i > 0) usleep(static_cast<useconds_t>(std::min<int64_t>(a[0].i, 3600000)) * 1000);
    return Value::none();
  });
  method(r, "Io", "fail", {"string"}, "void", [](void *, Args &a) -> Value {
    throw dslvm::Error("APP_FAIL", a[0].s);  // the script's own verdict: exit status 4
  });
  method(r, "Io", "sha256", {"string"}, "string", [](void *, Args &a) {
    std::string data = read_whole(a[0].s);
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    if (EVP_Digest(data.data(), data.size(), md, &n, EVP_sha256(), nullptr) != 1) throw dslvm::Error("Io.sha256: digest failed");
    static const char *hex = "0123456789abcdef";
    std::string out;
    for (unsigned i = 0; i < n; i++) { out += hex[md[i] >> 4]; out += hex[md[i] & 15]; }
    return Value::string(out);
  });
  method(r, "Io", "now", {}, "int", [](void *, Args &) { return Value::integer(static_cast<int64_t>(time(nullptr))); });

  // ---- Report ----
  method(r, "Report", "add", {"string", "string", "int", "string"}, "void", [](void *p, Args &a) {
    self<Report>(p)->findings.push_back(Finding{a[0].s, a[1].s, a[3].s, a[2].i});
    return Value::none();
  });
  method(r, "Report", "count", {}, "int", [](void *p, Args &) { return Value::integer(static_cast<int64_t>(self<Report>(p)->findings.size())); });
  method(r, "Report", "fail_if_any", {}, "void", [](void *p, Args &) {
    auto count = self<Report>(p)->findings.size();
    if (count) throw dslvm::Error("APP_FAIL", std::to_string(count) + " finding(s)");
    return Value::none();
  });
  method(r, "Report", "text", {}, "string", [](void *p, Args &) { return Value::string(report_text(*self<Report>(p))); });
  method(r, "Report", "print", {}, "void", [](void *p, Args &) {
    std::cout << report_text(*self<Report>(p));
    return Value::none();
  });
  method(r, "Report", "write_text", {"string"}, "void", [](void *p, Args &a) {
    std::ofstream file(a[0].s, std::ios::binary);
    if (!file) throw dslvm::Error("cannot write " + a[0].s);
    file << report_text(*self<Report>(p));
    return Value::none();
  });
  method(r, "Report", "write_json", {"string"}, "void", [](void *p, Args &a) {
    auto &fs_ = self<Report>(p)->findings;
    std::string out = "{\"findings\":[";
    for (size_t i = 0; i < fs_.size(); i++) {
      if (i) out += ",";
      out += "{\"kind\":" + json_text(fs_[i].kind) + ",\"file\":" + json_text(fs_[i].file) + ",\"line\":" +
             std::to_string(fs_[i].line) + ",\"message\":" + json_text(fs_[i].message) + "}";
    }
    out += "],\"count\":" + std::to_string(fs_.size()) + "}\n";
    std::ofstream file(a[0].s, std::ios::binary);
    if (!file) throw dslvm::Error("cannot write " + a[0].s);
    file << out;
    return Value::none();
  });
}

std::string schema_summary(const dslvm::Registry &reg) {
  std::vector<std::string> order;
  std::map<std::string, std::vector<std::string>> members;
  std::string current, out;
  for (const auto &signature : reg.signatures()) {
    if (signature.rfind("context ", 0) == 0) {
      out += "context " + signature.substr(8) + "\n";
    } else if (signature.rfind("fn ", 0) == 0) {
      out += "fn " + signature.substr(3) + "\n";
    } else if (signature.rfind("method ", 0) == 0) {
      std::string body = signature.substr(7);
      std::string type = body.substr(0, body.find('.'));
      if (type != current) { current = type; order.push_back(type); }
      members[type].push_back(body);
    }
  }
  for (const auto &type : order) {
    out += type + ":\n";
    for (const auto &member : members[type]) out += "  " + member + "\n";
  }
  return out;
}

}  // namespace lmssh
