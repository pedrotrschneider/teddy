#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*OpenDatabase)(const char *, void **);
typedef int (*CloseDatabase)(void *);

static void fail(const char *operation) {
  perror(operation);
  exit(2);
}

static void copy_library(const char *source, const char *destination) {
  int input = open(source, O_RDONLY);
  if (input < 0) fail("open source");
  // Every destination belongs to the freshly created test directory.
  int output = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0755);
  if (output < 0) fail("create fixture");
  char buffer[65536];
  ssize_t length;
  while ((length = read(input, buffer, sizeof(buffer))) > 0) {
    for (ssize_t offset = 0; offset < length;) {
      ssize_t written = write(output, buffer + offset, length - offset);
      if (written <= 0) fail("write fixture");
      offset += written;
    }
  }
  if (length < 0) fail("read source");
  if (close(input) || close(output)) fail("close fixture");
}

static void *load_library(const char *path) {
  void *library = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); exit(2); }
  return library;
}

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  const char *mode = argv[3];
  char original[4096], next[4096];
  snprintf(original, sizeof(original), "%s/current.dylib", argv[2]);
  snprintf(next, sizeof(next), "%s/next.dylib", argv[2]);
  copy_library(argv[1], original);
  void *first = load_library(original), *database = NULL;
  OpenDatabase open_first = (OpenDatabase)dlsym(first, "sqlite3_open");
  CloseDatabase close_first = (CloseDatabase)dlsym(first, "sqlite3_close_v2");
  if (!open_first || !close_first || open_first(":memory:", &database)) return 2;

  if (strcmp(mode, "unchanged") != 0) copy_library(argv[1], next);
  if (strcmp(mode, "replaced") == 0 && rename(next, original)) fail("replace fixture");
  void *reloaded = load_library(original);
  CloseDatabase close_reloaded = (CloseDatabase)dlsym(reloaded, "sqlite3_close_v2");
  int duplicate = close_first != close_reloaded;
  if (strcmp(mode, "replaced") == 0) {
    // The diagnostic reproducer proves close_reloaded(database) SIGSEGVs.
    // Detect the unsafe boundary without crashing on every regression run.
    if (!duplicate || close_first(database)) return 1;
    puts("replaced: duplicate mapping detected; original connection safely closed with its owner");
  } else {
    if (duplicate || close_reloaded(database)) return 1;
    if (strcmp(mode, "versioned") == 0) {
      void *new_library = load_library(next), *new_database = NULL;
      OpenDatabase open_next = (OpenDatabase)dlsym(new_library, "sqlite3_open");
      CloseDatabase close_next = (CloseDatabase)dlsym(new_library, "sqlite3_close_v2");
      if (!open_next || !close_next || open_next(":memory:", &new_database) || close_next(new_database)) return 1;
    } else if (strcmp(mode, "unchanged") != 0) {
      return 2;
    }
    printf("%s: original mapping preserved; SQLite open/close succeeded\n", mode);
  }
  return 0;
}
