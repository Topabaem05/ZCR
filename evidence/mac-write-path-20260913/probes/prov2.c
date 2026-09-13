#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <sys/xattr.h>
#include <copyfile.h>
static void hex(const char *label, int fd) {
    unsigned char v[64]; ssize_t n = fgetxattr(fd, "com.apple.provenance", v, sizeof v, 0, 0);
    printf("%s len=%zd value=", label, n);
    for (ssize_t i = 0; i < n; i++) printf("%02x", v[i]);
    printf("\n");
}
int main(int argc, char **argv) {
    int src = open(argv[1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);   /* read-only: the source file is never modified */
    if (src < 0) { perror("open source"); return 1; }
    hex("foreign-source", src);
    char t1[1024], t2[1024];
    snprintf(t1, sizeof t1, "%s/set-target.txt", argv[2]); snprintf(t2, sizeof t2, "%s/copy-target.txt", argv[2]);
    int a = open(t1, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600); write(a, "a", 1); hex("set-target-before", a);
    unsigned char v[64]; ssize_t n = fgetxattr(src, "com.apple.provenance", v, sizeof v, 0, 0);
    int rs = fsetxattr(a, "com.apple.provenance", v, n, 0, 0); printf("fsetxattr foreign value rc=%d errno=%s\n", rs, rs ? strerror(errno) : "0"); hex("set-target-after", a);
    int b = open(t2, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600); write(b, "b", 1); hex("copy-target-before", b);
    int rc = fcopyfile(src, b, NULL, COPYFILE_XATTR); printf("fcopyfile(COPYFILE_XATTR) rc=%d errno=%s\n", rc, rc ? strerror(errno) : "0"); hex("copy-target-after", b);
    close(src); close(a); close(b); unlink(t1); unlink(t2); return 0;
}
