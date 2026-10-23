#pragma once
/* The four OpenSSH client programs linked into this image. Their main() functions are renamed
 * lmssh_<tool>_main at build time (scripts/build-openssh.sh); tools.c runs them. */
#ifdef __cplusplus
extern "C" {
#endif

enum lmssh_tool { LMSSH_SSH = 0, LMSSH_SFTP = 1, LMSSH_SCP = 2, LMSSH_KEYGEN = 3 };

/* Absolute path of this executable. sftp and scp spawn their transport with it ("-S"), and ssh uses it
 * for ProxyJump; lmssh's own argv dispatch (cpp/main.cpp) turns that invocation back into ssh. */
void lmssh_set_self(const char *path);
const char *lmssh_get_self(void);

/* Runs one tool to completion with original OpenSSH semantics. argv[0] is replaced; argv[1..] are the
 * tool's own arguments. The tool may call exit(). */
int lmssh_run_tool(enum lmssh_tool tool, int argc, char **argv);

#ifdef __cplusplus
}
#endif
