#pragma once
#include "dslvm.hpp"
#include "runner.hpp"
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace lmssh {

// Connection settings: the Ssh context holds the defaults, every Session starts as a copy.
struct Options {
  std::string user, known_hosts, config, jump, strict_host_key, password;
  int port = 0;
  int connect_timeout = 30;  // seconds, ssh ConnectTimeout
  int timeout = 0;           // seconds per command; 0 = none
  int parallel = 8;          // Ssh.each() fan-out
  bool reuse = false;        // ControlMaster/ControlPersist multiplexing
  std::vector<std::string> identities, raw;  // raw: "Key=Value" for ssh -o
};

struct Session { std::string dest; Options opts; };
struct Result { std::string dest, command; Outcome outcome; };
struct ResultList { std::vector<Result *> items; };
struct StrList { std::vector<std::string> items; };
struct Key { std::string path; };
struct Finding { std::string kind, file, message; int64_t line; };
struct Report { std::vector<Finding> findings; };

struct Host {
  Options defaults;            // the Ssh context object
  int key_bits = 0;            // Keys.bits()
  Report report;
  std::vector<std::string> script_args;
  std::deque<Session> sessions;
  std::deque<Result> results;
  std::deque<ResultList> result_lists;
  std::deque<StrList> str_lists;
  std::deque<Key> keys;
  std::string work_dir;        // private 0700 directory under /tmp: scratch files and control sockets
  pid_t owner = 0;

  Host();
  ~Host();
  const std::string &work();   // created on first use
  void shutdown();             // closes multiplexed masters, removes work_dir; owner process only
};

void register_host(dslvm::Registry &registry, Host &host);
std::string schema_summary(const dslvm::Registry &registry);

}  // namespace lmssh
