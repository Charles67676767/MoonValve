/* Minimal native host: bounded byte IO and regular directory entries.
 * KV1 parsing, Steam models, filtering and serialization live in MoonBit. */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif
#include "moonbit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <wchar.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
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

MOONBIT_FFI_EXPORT moonbit_bytes_t moonvalve_read_range(moonbit_bytes_t path,int32_t offset,int32_t length) {
  mv_failed=0;
  if(offset<0 || length<0 || length>67108864) return mv_error();
  FILE *file;
#ifdef _WIN32
  wchar_t *wide=mv_wide((const char *)path);if(!wide)return mv_error();
  file=_wfopen(wide,L"rb");free(wide);
#else
  file=fopen((const char *)path,"rb");
#endif
  if(!file)return mv_error();
#ifdef _WIN32
  struct _stat64 info;
  if(_fstat64(_fileno(file),&info) || (info.st_mode&_S_IFMT)!=_S_IFREG || _fseeki64(file,offset,SEEK_SET)) {fclose(file);return mv_error();}
#else
  struct stat info;
  if(fstat(fileno(file),&info) || !S_ISREG(info.st_mode) || fseeko(file,(off_t)offset,SEEK_SET)) {fclose(file);return mv_error();}
#endif
  moonbit_bytes_t bytes=moonbit_make_bytes(length,0);
  size_t used=fread(bytes,1,(size_t)length,file);
  if(used!=(size_t)length || ferror(file))mv_failed=1;
  if(fclose(file))mv_failed=1;
  return bytes;
}

/* One active synchronous input stream per CLI invocation; chunks are bounded. */
static FILE *mv_stream;
MOONBIT_FFI_EXPORT int moonvalve_stream_open(moonbit_bytes_t path) {
  mv_failed = 0;
  if (mv_stream) { mv_failed=1; return -1; }
  if (!strcmp((const char *)path,"-")) {
    mv_stream=stdin;
#ifdef _WIN32
    _setmode(_fileno(stdin),_O_BINARY);
#endif
  } else {
#ifdef _WIN32
    wchar_t *wide=mv_wide((const char *)path);
    if (!wide) { mv_failed=1; return -1; }
    mv_stream=_wfopen(wide,L"rb"); free(wide);
#else
    mv_stream=fopen((const char *)path,"rb");
#endif
  }
  if (!mv_stream) mv_failed=1;
  return mv_stream?1:-1;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonvalve_stream_chunk(int32_t handle) {
  unsigned char buffer[65536];
  if (handle!=1 || !mv_stream) return mv_error();
#ifdef _WIN32
  int n=_read(_fileno(mv_stream),buffer,sizeof(buffer));
#else
  ssize_t n;
  do { n=read(fileno(mv_stream),buffer,sizeof(buffer)); } while(n<0 && errno==EINTR);
#endif
  if (n<0) return mv_error();
  return mv_result(buffer,(size_t)n);
}
MOONBIT_FFI_EXPORT void moonvalve_stream_close(int32_t handle) {
  if (handle==1 && mv_stream) { if(mv_stream!=stdin)fclose(mv_stream); mv_stream=NULL; }
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonvalve_read(moonbit_bytes_t path, int32_t limit) {
  mv_failed = 0;
  if (limit < 1 || limit > 536870912) return mv_error();
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
      if (capacity == (size_t)limit + 1) { mv_failed = 1; break; }
      size_t next = capacity * 2;
      if (next > (size_t)limit + 1) next = (size_t)limit + 1;
      void *grown = realloc(buffer, next);
      if (!grown) { mv_failed = 1; break; }
      buffer = grown; capacity = next;
    }
    size_t count = fread(buffer + used, 1, capacity - used, file);
    used += count;
    if (used > (size_t)limit || ferror(file)) { mv_failed = 1; break; }
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

#ifdef _WIN32
static wchar_t *mv_final_path(const wchar_t *path) {
  HANDLE file=CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
  if(file==INVALID_HANDLE_VALUE) return NULL;
  DWORD n=GetFinalPathNameByHandleW(file,NULL,0,FILE_NAME_NORMALIZED);
  wchar_t *result=n ? malloc(((size_t)n+1)*sizeof(wchar_t)) : NULL;
  if(result && !GetFinalPathNameByHandleW(file,result,n+1,FILE_NAME_NORMALIZED)) {free(result);result=NULL;}
  CloseHandle(file); return result;
}
#endif

MOONBIT_FFI_EXPORT moonbit_bytes_t moonvalve_confined(moonbit_bytes_t root,moonbit_bytes_t relative) {
  mv_failed=0;
  size_t length=strlen((const char*)root)+strlen((const char*)relative)+2;
  char *joined=malloc(length);
  if(!joined) return mv_error();
  snprintf(joined,length,"%s/%s",(const char*)root,(const char*)relative);
#ifdef _WIN32
  wchar_t *rw=mv_wide((const char*)root),*tw=mv_wide(joined);
  free(joined);
  wchar_t *base=rw ? mv_final_path(rw) : NULL,*target=tw ? mv_final_path(tw) : NULL;
  free(rw);free(tw);
  if(!base || !target) {free(base);free(target);return mv_error();}
  size_t n=wcslen(base),m=wcslen(target);
  while(n>0 && (base[n-1]==L'\\' || base[n-1]==L'/')) n--;
  int valid=m>n && !_wcsnicmp(base,target,n) && (target[n]==L'\\' || target[n]==L'/');
  free(base);
  if(!valid) {free(target);return mv_error();}
  int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,target,-1,NULL,0,NULL,NULL);
  char *utf=count>0 ? malloc((size_t)count) : NULL;
  if(!utf) {free(target);return mv_error();}
  int converted=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,target,-1,utf,count,NULL,NULL);
  free(target);
  moonbit_bytes_t result=converted ? mv_result(utf,(size_t)count-1) : mv_error();
  free(utf);return result;
#else
  char *base=realpath((const char*)root,NULL),*target=realpath(joined,NULL);
  free(joined);
  if(!base || !target) {free(base);free(target);return mv_error();}
  size_t n=strlen(base);
  while(n>1 && base[n-1]=='/') n--;
  struct stat status;
  int valid=!stat(base,&status) && S_ISDIR(status.st_mode) && !strncmp(base,target,n) && ((n==1 && base[0]=='/') || target[n]=='/');
  free(base);
  moonbit_bytes_t result=valid ? mv_result(target,strlen(target)) : mv_error();
  free(target);return result;
#endif
}

static int mv_matches(FILE *file,const unsigned char *bytes,size_t length) {
  unsigned char chunk[65536];size_t offset=0;
  if(!file) return 0;
  for(;;) {
    size_t n=fread(chunk,1,sizeof(chunk),file);
    if(n>length-offset || memcmp(chunk,bytes+offset,n)) return 0;
    offset+=n;
    if(!n) return !ferror(file) && offset==length;
  }
}

static int mv_flush_file(FILE *file) {
  if(fflush(file)) return 0;
#ifdef _WIN32
  return !_commit(_fileno(file));
#else
  return !fsync(fileno(file));
#endif
}

MOONBIT_FFI_EXPORT int moonvalve_save(moonbit_bytes_t path,moonbit_bytes_t before,int32_t old_length,moonbit_bytes_t after,int32_t new_length) {
  if(old_length<0 || new_length<0) return 1;
  static unsigned sequence=0;
  size_t n=strlen((const char*)path);
  char *temp=malloc(n+100),*backup=malloc(n+5);
  if(!temp || !backup) {free(temp);free(backup);return 1;}
  snprintf(backup,n+5,"%s.bak",(const char*)path);
  int result=1,created=0;
  FILE *original=NULL,*output=NULL,*backup_file=NULL;
#ifdef _WIN32
  wchar_t *target=mv_wide((const char*)path),*temp_w=NULL,*backup_w=mv_wide(backup);
  if(!target || !backup_w) goto done;
  DWORD attributes=GetFileAttributesW(target);
  if(attributes==INVALID_FILE_ATTRIBUTES || (attributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))) goto done;
  original=_wfopen(target,L"rb");
#else
  struct stat status;
  if(lstat((const char*)path,&status) || !S_ISREG(status.st_mode)) goto done;
  original=fopen((const char*)path,"rb");
#endif
  if(!mv_matches(original,before,(size_t)old_length)) goto done;
  fclose(original);original=NULL;
  for(int attempt=0;attempt<32;attempt++) {
#ifdef _WIN32
    snprintf(temp,n+100,"%s.moonvalve-%lu-%u",(const char*)path,(unsigned long)GetCurrentProcessId(),++sequence);
    free(temp_w);temp_w=mv_wide(temp);
    int fd=temp_w ? _wopen(temp_w,_O_WRONLY|_O_CREAT|_O_EXCL|_O_BINARY,_S_IREAD|_S_IWRITE) : -1;
    if(fd>=0) {output=_fdopen(fd,"wb");if(!output) _close(fd);created=1;break;}
#else
    snprintf(temp,n+100,"%s.moonvalve-%lu-%u",(const char*)path,(unsigned long)getpid(),++sequence);
    int fd=open(temp,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd>=0) {fchmod(fd,status.st_mode&0777);output=fdopen(fd,"wb");if(!output) close(fd);created=1;break;}
#endif
  }
  if(!output || fwrite(after,1,(size_t)new_length,output)!=(size_t)new_length || !mv_flush_file(output)) goto done;
  if(fclose(output)) {output=NULL;goto done;} output=NULL;
#ifdef _WIN32
  int backup_fd=_wopen(backup_w,_O_WRONLY|_O_CREAT|_O_EXCL|_O_BINARY,_S_IREAD|_S_IWRITE);
  if(backup_fd>=0) {backup_file=_fdopen(backup_fd,"wb");if(!backup_file) _close(backup_fd);}
  original=_wfopen(target,L"rb");
#else
  int backup_fd=open(backup,O_WRONLY|O_CREAT|O_EXCL,0600);
  if(backup_fd>=0) {fchmod(backup_fd,status.st_mode&0777);backup_file=fdopen(backup_fd,"wb");if(!backup_file) close(backup_fd);}
  original=fopen((const char*)path,"rb");
#endif
  if(!backup_file || fwrite(before,1,(size_t)old_length,backup_file)!=(size_t)old_length || !mv_flush_file(backup_file)) goto done;
  if(fclose(backup_file)) {backup_file=NULL;goto done;} backup_file=NULL;
  if(!mv_matches(original,before,(size_t)old_length)) goto done;
  fclose(original);original=NULL;
#ifdef _WIN32
  if(!ReplaceFileW(target,temp_w,NULL,0,NULL,NULL)) goto done;
#else
  struct stat current;
  if(lstat((const char*)path,&current) || current.st_dev!=status.st_dev || current.st_ino!=status.st_ino) goto done;
  if(rename(temp,(const char*)path)) goto done;
#endif
  created=0;result=0;
done:
  if(original) fclose(original);
  if(output) fclose(output);
  if(backup_file) fclose(backup_file);
#ifdef _WIN32
  if(created && temp_w) _wremove(temp_w);
  free(target);free(temp_w);free(backup_w);
#else
  if(created) unlink(temp);
#endif
  free(temp);free(backup);return result;
}


/* Export only into an exclusively created new directory. Track owned paths so
 * rollback never enumerates or recursively removes a user-selected tree. */
static char *mv_export_root;
static char *mv_export_owned[8192];
static unsigned char mv_export_is_dir[8192];
static size_t mv_export_count;
static void mv_export_remove_owned(const char *path,int directory) {
#ifdef _WIN32
  wchar_t *wide=mv_wide(path);if(wide){if(directory)RemoveDirectoryW(wide);else DeleteFileW(wide);free(wide);}
#else
  if(directory)rmdir(path);else unlink(path);
#endif
}
static int mv_export_track(const char *path, int directory) {
  if (mv_export_count >= 8192) return 0;
  size_t n=strlen(path)+1;char *copy=malloc(n);if(!copy)return 0;
  memcpy(copy,path,n);mv_export_owned[mv_export_count]=copy;
  mv_export_is_dir[mv_export_count++]=(unsigned char)directory;return 1;
}
static int mv_export_mkdir(const char *path) {
#ifdef _WIN32
  wchar_t *wide=mv_wide(path);if(!wide)return -1;
  int created=CreateDirectoryW(wide,NULL)!=0;
  DWORD error=GetLastError(),attrs=GetFileAttributesW(wide);free(wide);
  if(created)return 1;
  return error==ERROR_ALREADY_EXISTS && attrs!=INVALID_FILE_ATTRIBUTES &&
    (attrs&FILE_ATTRIBUTE_DIRECTORY) && !(attrs&FILE_ATTRIBUTE_REPARSE_POINT) ? 0 : -1;
#else
  if(!mkdir(path,0700))return 1;
  struct stat st;
  return errno==EEXIST && !lstat(path,&st) && S_ISDIR(st.st_mode) ? 0 : -1;
#endif
}
MOONBIT_FFI_EXPORT int moonvalve_export_begin(moonbit_bytes_t path) {
  if(mv_export_root)return 1;
  const char *target=(const char*)path;
  size_t n=strlen(target)+1;
  char *root=malloc(n);if(!root)return 1;memcpy(root,target,n);
  /* Existing files, directories, symlinks and Windows junctions all fail. */
#ifdef _WIN32
  wchar_t *wide=mv_wide(target);if(!wide){free(root);return 1;}
  int created=CreateDirectoryW(wide,NULL)!=0;free(wide);
#else
  int created=!mkdir(target,0700);
#endif
  if(!created){free(root);return 1;}
  mv_export_root=root;mv_export_count=0;
  return 0;
}
MOONBIT_FFI_EXPORT int moonvalve_export_file(moonbit_bytes_t relative,moonbit_bytes_t bytes,int32_t length) {
  if(!mv_export_root || length<0)return 1;
  const char *name=(const char*)relative;
  if(!*name || *name=='/' || strchr(name,'\\') || strchr(name,':') || strstr(name,"../"))return 1;
  size_t prefix=strlen(mv_export_root),size=prefix+strlen(name)+2;
  char *path=malloc(size);if(!path)return 1;
  snprintf(path,size,"%s/%s",mv_export_root,name);
  for(char *at=path+prefix+1;*at;at++)if(*at=='/'){
    *at=0;int made=mv_export_mkdir(path);
    if(made<0){free(path);return 1;}
    if(made && !mv_export_track(path,1)){mv_export_remove_owned(path,1);free(path);return 1;}
    *at='/';
  }
  FILE *file;
#ifdef _WIN32
  wchar_t *wide=mv_wide(path);
  file=wide?_wfopen(wide,L"wbx"):NULL;free(wide);
#else
  file=fopen(path,"wbx");
#endif
  if(!file){free(path);return 1;}
  int tracked=mv_export_track(path,0);
  if(!tracked){fclose(file);mv_export_remove_owned(path,0);free(path);return 1;}
  int failed=fwrite(bytes,1,(size_t)length,file)!=(size_t)length;
  if(fflush(file))failed=1;
  if(fclose(file))failed=1;
  free(path);return failed;
}
MOONBIT_FFI_EXPORT void moonvalve_export_finish(int32_t success) {
  if(!mv_export_root)return;
  while(mv_export_count){size_t i=--mv_export_count;char *path=mv_export_owned[i];
    if(!success){
#ifdef _WIN32
      wchar_t *wide=mv_wide(path);if(wide){if(mv_export_is_dir[i])RemoveDirectoryW(wide);else DeleteFileW(wide);free(wide);}
#else
      if(mv_export_is_dir[i])rmdir(path);else unlink(path);
#endif
    }
    free(path);
  }
  if(!success){
#ifdef _WIN32
    wchar_t *wide=mv_wide(mv_export_root);if(wide){RemoveDirectoryW(wide);free(wide);}
#else
    rmdir(mv_export_root);
#endif
  }
  free(mv_export_root);mv_export_root=NULL;
}

MOONBIT_FFI_EXPORT int moonvalve_write_new(moonbit_bytes_t target,moonbit_bytes_t bytes,int32_t length) {
  FILE *file;
#ifdef _WIN32
  wchar_t *wide=mv_wide((const char*)target);if(!wide)return 1;
  file=_wfopen(wide,L"wbx");
#else
  file=fopen((const char*)target,"wbx");
#endif
  if(!file){
#ifdef _WIN32
    free(wide);
#endif
    return 1;
  }
  int failed=fwrite(bytes,1,(size_t)length,file)!=(size_t)length;
  if(fflush(file))failed=1;if(fclose(file))failed=1;
#ifdef _WIN32
  if(failed)DeleteFileW(wide);free(wide);
#else
  if(failed)unlink((const char*)target);
#endif
  return failed;
}
