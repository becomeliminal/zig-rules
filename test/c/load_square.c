// Loads the shared library named on the command line and prints zig_square(8).
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: load_square LIBRARY\n");
        return 2;
    }
    void *lib = dlopen(argv[1], RTLD_NOW);
    if (lib == NULL) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    int (*zig_square)(int) = (int (*)(int))dlsym(lib, "zig_square");
    if (zig_square == NULL) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    printf("%d\n", zig_square(8));
    return 0;
}
