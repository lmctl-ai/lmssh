#pragma once
// Runs the linked OpenSSH tools in forked children with captured stdio. A child is a fresh copy of this
// process, so the tools keep their exit()/global-state behaviour; the parent only sees an exit status.
#include "tools.h"
#include <string>
#include <utility>
#include <vector>

namespace lmssh {

struct Spec {
  lmssh_tool tool = LMSSH_SSH;
  std::vector<std::string> args;                       // the tool's own arguments (no argv[0])
  std::string input;                                   // written to the child's stdin, then closed
  std::vector<std::pair<std::string, std::string>> env;  // set in the child only
  int timeout_ms = 0;                                  // 0 = none; the child's process group is killed
};

struct Outcome {
  int status = -1;           // exit status, 128+signal if killed, -1 if it never ran
  bool timed_out = false;
  bool dry = false;          // --dry-run: nothing executed
  std::string out, err, failure;  // failure: why it never ran (fork/pipe error)
};

void set_dry_run(bool on);
bool dry_run();
// Marks the process that owns temp files and masters; children forked by run_all() are not the owner.
bool is_owner();
void mark_owner();

// Runs every spec, at most `parallel` at once; results are in spec order.
std::vector<Outcome> run_all(const std::vector<Spec> &specs, size_t parallel);
Outcome run_one(const Spec &spec);

std::string command_line(const Spec &spec);  // for --dry-run and error messages
std::string self_executable(const char *argv0);

}  // namespace lmssh
