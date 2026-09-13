#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) { int f = open(argv[1], O_RDWR|O_CREAT|O_TRUNC, 0644); write(f, "x", 1); close(f); return 0; }
