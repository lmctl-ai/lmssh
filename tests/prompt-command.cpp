// Test-only SSH boundary: execute the real pinned VM command builder without a network or real home.
#include "dslvm.hpp"
#include <fstream>
#include <iostream>
int main(int argc,char**argv){
 if(argc<7)return 2;
 using namespace dslvm;Registry r;Context c;int io=0,ssh=0,session=0,result=0;std::vector<std::string> args;
 for(int i=5;i<argc;i++)args.push_back(argv[i]);
 r.context("io","Io").context("ssh","Ssh");c.set("io",&io);c.set("ssh",&ssh);
 r.method("Io","args",{},"StrList",[&](void*,Args&){return Value::object("StrList",r.std_collections().make_str_list(args));});
 for(auto name:{"print","eprint"})r.method("Io",name,{"string"},"void",[](void*,Args&){return Value::none();});
 r.method("Io","fail",{"string"},"void",[](void*,Args&a)->Value{throw Error(a[0].s);});
 r.method("Ssh","connect",{"string"},"Session",[&](void*,Args&){return Value::object("Session",&session);});
 r.method("Session","strict_host_key",{"string"},"Session",[&](void*,Args&){return Value::object("Session",&session);});
 for(auto name:{"connect_timeout","timeout"})r.method("Session",name,{"int"},"Session",[&](void*,Args&){return Value::object("Session",&session);});
 r.method("Session","exec",{"string","string"},"Result",[&](void*,Args&a){std::ofstream(argv[3],std::ios::binary)<<a[0].s;std::ofstream(argv[4],std::ios::binary)<<a[1].s;return Value::object("Result",&result);});
 for(auto name:{"stdout","stderr"})r.method("Result",name,{},"string",[](void*,Args&){return Value::string("");});
 r.method("Result","ok",{},"bool",[](void*,Args&){return Value::boolean(true);});
 try{Program::load(read_file(argv[1]),read_file(argv[2]),r).run(c,r);return 0;}
 catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 3;}
}
