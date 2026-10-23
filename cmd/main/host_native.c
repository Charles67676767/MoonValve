/* Minimal native host: bounded byte IO and regular directory entries.
 * KV1 parsing, Steam models, filtering and serialization live in MoonBit. */
#include "moonbit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>
#endif

#define MV_LIMIT (16u * 1024u * 1024u)
static int mv_failed;

static moonbit_bytes_t mv_result(const void *data, size_t size) {
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)size, 0);
  if (size) memcpy(bytes, data, size);
  return bytes;
}
static moonbit_bytes_t mv_error(void) { mv_failed = 1; return mv_result(NULL, 0); }
MOONBIT_FFI_EXPORT int moonvalve_failed(void) { return mv_failed; }

#ifdef _WIN32
static wchar_t *mv_wide(const char *text) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (!n) return NULL;
  wchar_t *result = malloc((size_t)n * sizeof(wchar_t));
  if (!result) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result, n)) { free(result); return NULL; }
  return result;
}
#endif

MOONBIT_FFI_EXPORT moonbit_bytes_t moonvalve_read(moonbit_bytes_t path) {
  mv_failed = 0;
  FILE *file;
  if (!strcmp((const char *)path, "-")) {
    file = stdin;
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
#endif
  } else {
#ifdef _WIN32
    wchar_t *wide = mv_wide((const char *)path);
    if (!wide) return mv_error();
    file = _wfopen(wide, L"rb");
    free(wide);
#else
    file = fopen((const char *)path, "rb");
#endif
  }
  if (!file) return mv_error();
  size_t capacity = 65536, used = 0;
  unsigned char *buffer = malloc(capacity);
  if (!buffer) { if (file != stdin) fclose(file); return mv_error(); }
  for (;;) {
    if (used == capacity) {
      if (capacity == MV_LIMIT + 1) { mv_failed = 1; break; }
      size_t next = capacity * 2;
      if (next > MV_LIMIT + 1) next = MV_LIMIT + 1;
      void *grown = realloc(buffer, next);
      if (!grown) { mv_failed = 1; break; }
      buffer = grown; capacity = next;
    }
    size_t count = fread(buffer + used, 1, capacity - used, file);
    used += count;
    if (used > MV_LIMIT || ferror(file)) { mv_failed = 1; break; }
    if (!count) break;
  }
  if (file != stdin && fclose(file)) mv_failed = 1;
  moonbit_bytes_t result = mv_failed ? mv_result(NULL, 0) : mv_result(buffer, used);
  free(buffer);
  return result;
}

/* Append a NUL-terminated UTF-8 name. Bound both total bytes and entry count. */
static int mv_append(char **buffer, size_t *used, size_t *capacity, const char *name) {
  size_t n = strlen(name) + 1;
  if (n > MV_LIMIT - *used) return 0;
  if (*used + n > *capacity) {
    size_t next = (*used + n) * 2;
    if (next > MV_LIMIT) next = MV_LIMIT;
    void *grown = realloc(*buffer, next);
    if (!grown) return 0;
    *buffer = grown; *capacity = next;
  }
  memcpy(*buffer + *used, name, n); *used += n;
  return 1;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonvalve_list(moonbit_bytes_t path) {
  mv_failed = 0;
  char *buffer = NULL;
  size_t used = 0, capacity = 0;
  unsigned count = 0;
#ifdef _WIN32
  wchar_t *wide = mv_wide((const char *)path);
  if (!wide) return mv_error();
  size_t n = wcslen(wide);
  wchar_t *pattern = malloc((n + 3) * sizeof(wchar_t));
  if (!pattern) { free(wide); return mv_error(); }
  memcpy(pattern, wide, n * sizeof(wchar_t));
  pattern[n] = L'/'; pattern[n+1] = L'*'; pattern[n+2] = 0;
  free(wide);
  WIN32_FIND_DATAW entry;
  HANDLE handle = FindFirstFileW(pattern, &entry);
  free(pattern);
  if (handle == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND) return mv_result(NULL, 0);
    return mv_error();
  }
  do {
    if (entry.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) continue;
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, entry.cFileName, -1, NULL, 0, NULL, NULL);
    char *name = length > 0 ? malloc((size_t)length) : NULL;
    if (!name) { mv_failed = 1; break; }
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, entry.cFileName, -1, name, length, NULL, NULL) ||
        ++count > 100000 || !mv_append(&buffer, &used, &capacity, name)) mv_failed = 1;
    free(name);
    if (mv_failed) break;
  } while (FindNextFileW(handle, &entry));
  if (!mv_failed && GetLastError() != ERROR_NO_MORE_FILES) mv_failed = 1;
  FindClose(handle);
#else
  DIR *directory = opendir((const char *)path);
  if (!directory) return mv_error();
  struct dirent *entry;
  for (;;) {
    errno = 0;
    entry = readdir(directory);
    if (!entry) { if (errno) mv_failed = 1; break; }
    size_t n = strlen((const char *)path) + strlen(entry->d_name) + 2;
    char *full = malloc(n);
    if (!full) { mv_failed = 1; break; }
    snprintf(full, n, "%s/%s", (const char *)path, entry->d_name);
    struct stat status;
    int ok = lstat(full, &status);
    free(full);
    if (ok) { mv_failed = 1; break; }
    if (!S_ISREG(status.st_mode)) continue;
    if (++count > 100000 || !mv_append(&buffer, &used, &capacity, entry->d_name)) { mv_failed = 1; break; }
  }
  if (closedir(directory)) mv_failed = 1;
#endif
  moonbit_bytes_t result = mv_failed ? mv_result(NULL, 0) : mv_result(buffer, used);
  free(buffer);
  return result;
}

MOONBIT_FFI_EXPORT int moonvalve_write(moonbit_bytes_t bytes, int32_t length, int32_t error) {
  FILE *stream = error ? stderr : stdout;
#ifdef _WIN32
  _setmode(_fileno(stream), _O_BINARY);
#endif
  return fwrite(bytes, 1, (size_t)length, stream) != (size_t)length || fflush(stream);
}
MOONBIT_FFI_EXPORT void moonvalve_exit(int32_t code) { exit(code); }
