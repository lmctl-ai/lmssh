#include "dslvm.hpp"
#include "host.hpp"
#include "runner.hpp"
#include "schema_embedded.hpp"
#include "tools.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

const char *kUsage =
    "usage: lmssh --version | --dsl-schema [--json] | --dsl-signatures | [--dry-run] --dsl FILE [FILE ...] [-- ARG ...]\n"
    "       lmssh ssh|sftp|scp|ssh-keygen [OPENSSH OPTIONS ...]   the original OpenSSH clients, unchanged\n"
    "       (also run when this executable is invoked as ssh, sftp, scp or ssh-keygen)\n"
    "automation: compile an lmscript _dsl_ block against `lmssh --dsl-schema --json`, then run it with --dsl.\n";

bool is_tool_name(const std::string &name, lmssh_tool &tool) {
  if (name == "ssh") tool = LMSSH_SSH;
  else if (name == "sftp") tool = LMSSH_SFTP;
  else if (name == "scp") tool = LMSSH_SCP;
  else if (name == "ssh-keygen" || name == "keygen") tool = LMSSH_KEYGEN;
  else return false;
  return true;
}

std::string base_name(const char *path) {
  std::string p = path ? path : "";
  auto slash = p.find_last_of('/');
  return slash == std::string::npos ? p : p.substr(slash + 1);
}

// SSH_ASKPASS helper: ssh runs this executable as `<self> "<prompt>"` and reads the answer from stdout.
int askpass(const std::string &prompt) {
  const char *secret = getenv("LMSSH_ASKPASS_SECRET");
  if (prompt.find("(yes/no") != std::string::npos) {
    std::puts("no");  // never trust an unknown host key unattended: set strict_host_key("accept-new") to allow it
    return 0;
  }
  std::puts(secret ? secret : "");
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  static std::string self = lmssh::self_executable(argc > 0 ? argv[0] : nullptr);
  lmssh_set_self(self.c_str());
  lmssh_tool tool;

  // Invoked as ssh/sftp/scp/ssh-keygen (a symlink or copy): behave exactly like that program.
  if (argc > 0 && is_tool_name(base_name(argv[0]), tool) && base_name(argv[0]) != "keygen")
    return lmssh_run_tool(tool, argc, argv);
  if (argc == 2 && getenv("LMSSH_ASKPASS_SECRET") && argv[1][0] != '-' && !is_tool_name(argv[1], tool))
    return askpass(argv[1]);
  if (argc >= 2 && argv[1][0] == '-' && argv[1][1] != '-') {
    // Not a lmssh option: this is the ssh transport that sftp, scp and ProxyJump start from this executable.
    return lmssh_run_tool(LMSSH_SSH, argc, argv);
  }
  const std::string command = argc >= 2 ? argv[1] : "";
  if (argc >= 2 && is_tool_name(command, tool)) return lmssh_run_tool(tool, argc - 1, argv + 1);

  lmssh::Host host;
  dslvm::Registry reg;
  lmssh::register_host(reg, host);

  if (argc == 2 && command == "--version") {
    std::cout << "lmssh " LMSSH_VERSION "\n";
    return std::cout ? 0 : 4;
  }
  if (argc >= 2 && command == "--dsl-schema") {
    if (argc == 2) {
      std::cout << lmssh::schema_summary(reg);
      return std::cout ? 0 : 4;
    }
    if (argc == 3 && std::string(argv[2]) == "--json") {
      std::cout.write(reinterpret_cast<const char *>(lmssh::embedded_schema),
                      static_cast<std::streamsize>(lmssh::embedded_schema_size));
      return std::cout ? 0 : 4;
    }
    std::cerr << kUsage;
    return 2;
  }
  if (argc == 2 && command == "--dsl-signatures") {
    for (const auto &signature : reg.signatures()) std::cout << signature << "\n";
    return 0;
  }

  int files_at = 2;
  if (argc >= 2 && command == "--dry-run") {
    lmssh::set_dry_run(true);
    files_at = 3;
  }
  if (argc <= files_at || std::string(argv[files_at - 1]) != "--dsl") {
    std::cerr << kUsage;
    return 2;
  }
  // Validate the whole invocation before any block can touch a remote machine.
  int end = files_at;
  for (; end < argc && std::string(argv[end]) != "--"; end++) {
    if (std::string(argv[end]).empty() || std::string(argv[end]).rfind("--", 0) == 0) {
      std::cerr << kUsage;
      return 2;
    }
  }
  if (end == files_at) {
    std::cerr << kUsage;
    return 2;
  }
  for (int i = end + 1; i < argc; i++) host.script_args.push_back(argv[i]);

  const std::string schema(reinterpret_cast<const char *>(lmssh::embedded_schema), lmssh::embedded_schema_size);
  dslvm::Context context;
  context.set("ssh", &host.defaults);
  context.set("keys", &host);
  context.set("io", &host);
  context.set("report", &host.report);
  // Load and verify every file first: a missing or corrupt later file must not leave earlier blocks half-run.
  std::vector<dslvm::Program> programs;
  for (int i = files_at; i < end; i++) {
    try {
      programs.push_back(dslvm::Program::load(dslvm::read_file(argv[i]), schema, reg));
    } catch (const dslvm::Error &error) {
      return dslvm::report_error("load", error);
    }
  }
  for (const auto &program : programs) {
    try {
      program.run(context, reg);
    } catch (const dslvm::Error &error) {
      host.shutdown();
      return dslvm::report_error("run", error);
    }
    dslvm::report_ok();
  }
  host.shutdown();
  return 0;
}
