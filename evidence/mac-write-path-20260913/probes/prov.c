#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <sys/xattr.h>
#include <copyfile.h>
static void show(const char *label, int fd) {
    char names[1024]; ssize_t n = flistxattr(fd, names, sizeof names, XATTR_SHOWCOMPRESSION);
    printf("%s: flistxattr=%zd", label, n);
    for (ssize_t i = 0; n > 0 && i < n; i += strlen(names + i) + 1) {
        unsigned char v[64]; ssize_t len = fgetxattr(fd, names + i, v, sizeof v, 0, 0);
        printf(" [%s len=%zd:", names + i, len);
        for (ssize_t k = 0; k < len; k++) printf("%02x", v[k]);
        printf("]");
    }
    printf("\n");
}
int main(int argc, char **argv) {
    char a[1024], b[1024], c[1024];
    snprintf(a, sizeof a, "%s/orig.txt", argv[1]); snprintf(b, sizeof b, "%s/temp.txt", argv[1]); snprintf(c, sizeof c, "%s/copied.txt", argv[1]);
    int fa = open(a, O_RDWR|O_CREAT|O_TRUNC, 0644); write(fa, "orig", 4); show("orig", fa);
    int fb = open(b, O_RDWR|O_CREAT|O_TRUNC, 0644); write(fb, "temp", 4); show("temp", fb);
    unsigned char v[64]; ssize_t len = fgetxattr(fa, "com.apple.provenance", v, sizeof v, 0, 0);
    int rm = fremovexattr(fb, "com.apple.provenance", 0); printf("remove on temp=%d errno=%s\n", rm, rm ? strerror(errno) : "0"); show("temp-after-remove", fb);
    if (len > 0) { int rs = fsetxattr(fb, "com.apple.provenance", v, len, 0, 0); printf("set orig value on temp=%d errno=%s\n", rs, rs ? strerror(errno) : "0"); }
    unsigned char fake[11] = {1,2,3,4,5,6,7,8,9,10,11};
    int rf = fsetxattr(fb, "com.apple.provenance", fake, 11, 0, 0); printf("set arbitrary value=%d errno=%s\n", rf, rf ? strerror(errno) : "0"); show("temp-after-set", fb);
    int fc = open(c, O_RDWR|O_CREAT|O_TRUNC, 0644); write(fc, "copy", 4);
    int rc = fcopyfile(fa, fc, NULL, COPYFILE_XATTR); printf("fcopyfile xattr=%d errno=%s\n", rc, rc ? strerror(errno) : "0"); show("copied", fc);
    close(fa); close(fb); close(fc); return 0;
}
