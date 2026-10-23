#include "tools.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int lmssh_ssh_main(int, char **);
int lmssh_sftp_main(int, char **);
int lmssh_scp_main(int, char **);
int lmssh_ssh_keygen_main(int, char **);
void lmssh_ssh_cleanup_exit(int);
void lmssh_scp_cleanup_exit(int);

extern char *__progname; /* OpenSSH prints and logs under this name */

static const char *self_path = "ssh";
static enum lmssh_tool current_tool = LMSSH_SSH;

void lmssh_set_self(const char *path) { self_path = path; }
const char *lmssh_get_self(void) { return self_path; }

/* OpenSSH's libssh (fatal(), sshbuf errors, ...) calls cleanup_exit(); each tool defines its own. */
void cleanup_exit(int i) {
	switch (current_tool) {
	case LMSSH_SSH: lmssh_ssh_cleanup_exit(i); break;
	case LMSSH_SCP: lmssh_scp_cleanup_exit(i); break;
	default: break;
	}
	_exit(i);
}

int lmssh_run_tool(enum lmssh_tool tool, int argc, char **argv) {
	char **av = calloc((size_t)argc + 4, sizeof *av);
	int n = 0;
	if (av == NULL)
		return 255;
	current_tool = tool;
	{
		static char *names[] = {"ssh", "sftp", "scp", "ssh-keygen"};
		__progname = names[tool];
	}
	switch (tool) {
	case LMSSH_SSH:
		av[n++] = (char *)self_path; /* ProxyJump re-runs argv[0] */
		break;
	case LMSSH_SFTP:
	case LMSSH_SCP:
		av[n++] = (char *)(tool == LMSSH_SFTP ? "sftp" : "scp");
		av[n++] = (char *)"-S"; /* the transport is this image, not a system ssh */
		av[n++] = (char *)self_path;
		break;
	case LMSSH_KEYGEN:
		av[n++] = (char *)"ssh-keygen";
		break;
	}
	for (int i = 1; i < argc; i++)
		av[n++] = argv[i];
	av[n] = NULL;
	switch (tool) {
	case LMSSH_SSH: return lmssh_ssh_main(n, av);
	case LMSSH_SFTP: return lmssh_sftp_main(n, av);
	case LMSSH_SCP: return lmssh_scp_main(n, av);
	default: return lmssh_ssh_keygen_main(n, av);
	}
}
