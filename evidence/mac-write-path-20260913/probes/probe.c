#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/mount.h>
int main(int argc, char **argv) {
    const char *dir = argv[1];
    char file[1024]; snprintf(file, sizeof file, "%s/probe.bin", dir);
    int f = open(file, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (f < 0) { perror("open file"); return 1; }
    if (write(f, "data", 4) != 4) { perror("write"); return 1; }
    int r1 = fcntl(f, F_FULLFSYNC); int e1 = r1 ? errno : 0;
    int r2 = fsync(f); int e2 = r2 ? errno : 0;
    int d = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int r3 = fcntl(d, F_FULLFSYNC); int e3 = r3 ? errno : 0;
    int r4 = fsync(d); int e4 = r4 ? errno : 0;
    struct statfs sf; statfs(dir, &sf);
    printf("fs=%s file_fullfsync=%d(%s) file_fsync=%d(%s) dir_fullfsync=%d(%s) dir_fsync=%d(%s)\n", sf.f_fstypename,
        r1, strerror(e1), r2, strerror(e2), r3, strerror(e3), r4, strerror(e4));
    close(f); close(d); unlink(file); return 0;
}
