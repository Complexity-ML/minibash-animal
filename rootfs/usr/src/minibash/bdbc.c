#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define VERSION "0.5.0-native"
#define BDB_MAGIC "BDB1"
#define WAL_MAGIC "BWL1"

typedef struct {
  const char *target;
  const char *staged;
} WalEntry;

typedef struct { char *name; char *type; bool pk; } Column;
typedef struct { Column *cols; size_t len; int pk_idx; } Schema;
typedef struct { char *col; char *val; } Assign;
typedef struct { char ***rows; size_t len; } RowSet;

static void die(const char *fmt, ...) {
  va_list ap;
  fprintf(stderr, "bdbc: ");
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(1);
}

static char *xstrdup(const char *s) {
  char *p = strdup(s ? s : "");
  if (!p) die("out of memory");
  return p;
}

static char *xasprintf(const char *fmt, ...) {
  va_list ap;
  char *out = NULL;
  va_start(ap, fmt);
  if (vasprintf(&out, fmt, ap) < 0) die("out of memory");
  va_end(ap);
  return out;
}

static const char *db_dir(void) {
  const char *p = getenv("BDB_PATH");
  return (p && *p) ? p : ".bdb";
}

static bool is_name(const char *s) {
  if (!s || !*s) return false;
  if (!(isalpha((unsigned char)s[0]) || s[0] == '_')) return false;
  for (size_t i = 1; s[i]; i++) {
    if (!(isalnum((unsigned char)s[i]) || s[i] == '_')) return false;
  }
  return true;
}

static bool exists_dir(const char *p) {
  struct stat st;
  return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static char *table_dir(const char *table) { return xasprintf("%s/tables/%s", db_dir(), table); }
static char *schema_path(const char *table) { return xasprintf("%s/schema.bdb", table_dir(table)); }
static char *data_path(const char *table) { return xasprintf("%s/data.bdb", table_dir(table)); }

static void sync_fd(int fd, const char *path) {
  if (fsync(fd) != 0) die("fsync %s: %s", path, strerror(errno));
}

static void sync_file(FILE *f, const char *path) {
  if (fflush(f) != 0) die("flush %s: %s", path, strerror(errno));
  sync_fd(fileno(f), path);
}

static void sync_dir(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY);
  if (fd < 0) die("open directory %s: %s", path, strerror(errno));
  sync_fd(fd, path);
  close(fd);
}

static void mkdir_p(const char *path) {
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof(tmp), "%s", path);
  for (char *p = tmp + 1; *p; p++) {
    if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
  }
  if (mkdir(tmp, 0755) && errno != EEXIST) die("mkdir %s: %s", path, strerror(errno));
}

static void require_db(void) {
  char *p = xasprintf("%s/tables", db_dir());
  bool ok = exists_dir(p);
  free(p);
  if (!ok) die("base introuvable: %s (lance: bdb init)", db_dir());
}

static void require_table(const char *table) {
  char *p = table_dir(table);
  bool ok = exists_dir(p);
  free(p);
  if (!ok) die("table introuvable: %s", table);
}

static void write_u32(FILE *f, uint32_t v) {
  unsigned char b[4] = {(unsigned char)(v & 255), (unsigned char)((v >> 8) & 255), (unsigned char)((v >> 16) & 255), (unsigned char)((v >> 24) & 255)};
  if (fwrite(b, 1, 4, f) != 4) die("write failed");
}

static uint32_t read_u32(FILE *f) {
  unsigned char b[4];
  if (fread(b, 1, 4, f) != 4) die("native read failed");
  return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static void write_str(FILE *f, const char *s) {
  size_t n = strlen(s);
  if (n > UINT32_MAX) die("field too large");
  write_u32(f, (uint32_t)n);
  if (n && fwrite(s, 1, n, f) != n) die("write failed");
}

static char *read_str(FILE *f) {
  uint32_t n = read_u32(f);
  if (n > 64U * 1024U * 1024U) die("champ natif trop grand");
  char *s = calloc((size_t)n + 1, 1);
  if (!s) die("out of memory");
  if (n && fread(s, 1, n, f) != n) die("native read failed");
  return s;
}

static void write_magic(FILE *f) {
  if (fwrite(BDB_MAGIC, 1, 4, f) != 4) die("write failed");
}

static uint32_t crc32_update(uint32_t crc, const unsigned char *data, size_t len) {
  crc = ~crc;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; bit++)
      crc = (crc >> 1) ^ (0xedb88320U & (uint32_t)-(int32_t)(crc & 1));
  }
  return ~crc;
}

static uint32_t file_crc32(FILE *f, uint64_t *size) {
  unsigned char buf[16384];
  uint32_t crc = 0;
  *size = 0;
  rewind(f);
  for (;;) {
    size_t n = fread(buf, 1, sizeof(buf), f);
    if (n) {
      crc = crc32_update(crc, buf, n);
      *size += n;
    }
    if (n < sizeof(buf)) {
      if (ferror(f)) die("read staged file failed");
      break;
    }
  }
  rewind(f);
  return crc;
}

static void copy_bytes(FILE *src, FILE *dst, uint64_t size) {
  unsigned char buf[16384];
  while (size) {
    size_t want = size < sizeof(buf) ? (size_t)size : sizeof(buf);
    size_t n = fread(buf, 1, want, src);
    if (n != want || fwrite(buf, 1, n, dst) != n) die("copy failed");
    size -= n;
  }
}

static void write_u64(FILE *f, uint64_t v) {
  write_u32(f, (uint32_t)(v & UINT32_MAX));
  write_u32(f, (uint32_t)(v >> 32));
}

static uint64_t read_u64(FILE *f) {
  uint64_t lo = read_u32(f), hi = read_u32(f);
  return lo | (hi << 32);
}

static char *parent_dir(const char *path) {
  char *out = xstrdup(path);
  char *slash = strrchr(out, '/');
  if (!slash) {
    free(out);
    return xstrdup(".");
  }
  if (slash == out) slash[1] = 0;
  else *slash = 0;
  return out;
}

static void install_payload(const char *target, FILE *wal, uint64_t size, uint32_t expected_crc) {
  char *parent = parent_dir(target);
  char *tmp = xasprintf("%s/.bdb-recover-%ld.tmp", parent, (long)getpid());
  FILE *out = fopen(tmp, "wb");
  if (!out) die("open %s: %s", tmp, strerror(errno));
  uint32_t crc = 0;
  unsigned char buf[16384];
  uint64_t left = size;
  while (left) {
    size_t want = left < sizeof(buf) ? (size_t)left : sizeof(buf);
    size_t n = fread(buf, 1, want, wal);
    if (n != want) die("WAL tronque");
    crc = crc32_update(crc, buf, n);
    if (fwrite(buf, 1, n, out) != n) die("write %s failed", tmp);
    left -= n;
  }
  if (crc != expected_crc) die("checksum WAL invalide pour %s", target);
  sync_file(out, tmp);
  if (fclose(out) != 0) die("close %s: %s", tmp, strerror(errno));
  if (rename(tmp, target) != 0) die("rename %s: %s", target, strerror(errno));
  sync_dir(parent);
  free(tmp);
  free(parent);
}

static void recover_wal(void) {
  char *wal_path = xasprintf("%s/WAL", db_dir());
  FILE *wal = fopen(wal_path, "rb");
  if (!wal) {
    if (errno != ENOENT) die("open WAL: %s", strerror(errno));
    free(wal_path);
    return;
  }
  char magic[4];
  if (fread(magic, 1, 4, wal) != 4 || memcmp(magic, WAL_MAGIC, 4) != 0)
    die("WAL invalide: %s", wal_path);
  uint32_t version = read_u32(wal), count = read_u32(wal);
  if (version != 1 || count > 64) die("WAL incompatible: %s", wal_path);
  for (uint32_t i = 0; i < count; i++) {
    char *target = read_str(wal);
    uint64_t size = read_u64(wal);
    uint32_t crc = read_u32(wal);
    size_t root_len = strlen(db_dir());
    if (strncmp(target, db_dir(), root_len) != 0 || target[root_len] != '/')
      die("cible WAL hors base: %s", target);
    install_payload(target, wal, size, crc);
    free(target);
  }
  fclose(wal);
  if (unlink(wal_path) != 0) die("clear WAL: %s", strerror(errno));
  sync_dir(db_dir());
  free(wal_path);
}

static void cleanup_stale_files(void) {
  char *wal_tmp = xasprintf("%s/.WAL.tmp", db_dir());
  unlink(wal_tmp);
  free(wal_tmp);
  char *tables = xasprintf("%s/tables", db_dir());
  DIR *d = opendir(tables);
  if (!d) {
    free(tables);
    return;
  }
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strncmp(e->d_name, ".drop-", 6)) {
      char *dir = xasprintf("%s/%s", tables, e->d_name);
      char *schema = xasprintf("%s/schema.bdb", dir);
      char *data = xasprintf("%s/data.bdb", dir);
      unlink(schema);
      unlink(data);
      rmdir(dir);
      free(data);
      free(schema);
      free(dir);
      continue;
    }
    if (e->d_name[0] == '.') continue;
    char *dir = xasprintf("%s/%s", tables, e->d_name);
    if (exists_dir(dir)) {
      char *schema_tmp = xasprintf("%s/.schema.bdb.tmp", dir);
      char *data_tmp = xasprintf("%s/.data.bdb.tmp", dir);
      unlink(schema_tmp);
      unlink(data_tmp);
      free(data_tmp);
      free(schema_tmp);
    }
    free(dir);
  }
  closedir(d);
  free(tables);
}

static void commit_files(const WalEntry *entries, size_t count) {
  char *wal_path = xasprintf("%s/WAL", db_dir());
  char *wal_tmp = xasprintf("%s/.WAL.tmp", db_dir());
  FILE *wal = fopen(wal_tmp, "wb");
  if (!wal) die("open %s: %s", wal_tmp, strerror(errno));
  if (fwrite(WAL_MAGIC, 1, 4, wal) != 4) die("write WAL failed");
  write_u32(wal, 1);
  write_u32(wal, (uint32_t)count);
  for (size_t i = 0; i < count; i++) {
    FILE *src = fopen(entries[i].staged, "rb");
    if (!src) die("open %s: %s", entries[i].staged, strerror(errno));
    uint64_t size;
    uint32_t crc = file_crc32(src, &size);
    write_str(wal, entries[i].target);
    write_u64(wal, size);
    write_u32(wal, crc);
    copy_bytes(src, wal, size);
    fclose(src);
  }
  sync_file(wal, wal_tmp);
  if (fclose(wal) != 0) die("close WAL: %s", strerror(errno));
  if (rename(wal_tmp, wal_path) != 0) die("publish WAL: %s", strerror(errno));
  sync_dir(db_dir());
  if (getenv("BDB_TEST_CRASH_AFTER_WAL")) _exit(99);
  recover_wal();
  for (size_t i = 0; i < count; i++) unlink(entries[i].staged);
  free(wal_tmp);
  free(wal_path);
}

static void read_magic(FILE *f, const char *path) {
  char magic[4];
  if (fread(magic, 1, 4, f) != 4 || memcmp(magic, BDB_MAGIC, 4) != 0) die("format natif invalide: %s", path);
}

static void free_schema(Schema *s) {
  for (size_t i = 0; i < s->len; i++) { free(s->cols[i].name); free(s->cols[i].type); }
  free(s->cols);
}

static Schema load_schema(const char *table) {
  char *path = schema_path(table);
  FILE *f = fopen(path, "rb");
  if (!f) die("schema natif introuvable: %s", path);
  read_magic(f, path);
  uint32_t version = read_u32(f), cols = read_u32(f), pk_idx = read_u32(f);
  if (version != 1 || cols > 4096 || (pk_idx != UINT32_MAX && pk_idx >= cols))
    die("schema natif incompatible: %s", path);
  Schema s = {.len = cols, .pk_idx = pk_idx == UINT32_MAX ? -1 : (int)pk_idx};
  s.cols = calloc(s.len, sizeof(Column));
  if (!s.cols && s.len) die("out of memory");
  for (size_t i = 0; i < s.len; i++) {
    s.cols[i].name = read_str(f);
    s.cols[i].type = read_str(f);
    s.cols[i].pk = read_u32(f) == 1;
  }
  if (fgetc(f) != EOF) die("donnees en trop dans le schema: %s", path);
  fclose(f);
  free(path);
  return s;
}

static char *stage_schema(const char *table, const Schema *s) {
  char *td = table_dir(table), *tmp = xasprintf("%s/.schema.bdb.tmp", td);
  FILE *f = fopen(tmp, "wb");
  if (!f) die("open %s: %s", tmp, strerror(errno));
  write_magic(f); write_u32(f, 1); write_u32(f, (uint32_t)s->len); write_u32(f, s->pk_idx < 0 ? UINT32_MAX : (uint32_t)s->pk_idx);
  for (size_t i = 0; i < s->len; i++) { write_str(f, s->cols[i].name); write_str(f, s->cols[i].type); write_u32(f, s->cols[i].pk ? 1 : 0); }
  sync_file(f, tmp);
  if (fclose(f) != 0) die("close %s: %s", tmp, strerror(errno));
  free(td);
  return tmp;
}

static void free_row(char **row, size_t cols) {
  for (size_t i = 0; i < cols; i++) free(row[i]);
  free(row);
}

static void free_rowset(RowSet *rs, size_t cols) {
  for (size_t i = 0; i < rs->len; i++) free_row(rs->rows[i], cols);
  free(rs->rows);
}

static RowSet read_rows_path(const char *path, const Schema *s) {
  FILE *f = fopen(path, "rb");
  if (!f) die("data natif introuvable: %s", path);
  read_magic(f, path);
  uint32_t version = read_u32(f), cols = read_u32(f), rows = read_u32(f);
  if (version != 1 || cols != s->len || rows > 10000000)
    die("data natif incompatible: %s", path);
  RowSet rs = {.len = rows, .rows = calloc(rows, sizeof(char **))};
  if (!rs.rows && rows) die("out of memory");
  for (size_t r = 0; r < rs.len; r++) {
    rs.rows[r] = calloc(s->len, sizeof(char *));
    if (!rs.rows[r]) die("out of memory");
    for (size_t c = 0; c < s->len; c++) rs.rows[r][c] = read_str(f);
  }
  if (fgetc(f) != EOF) die("donnees en trop dans la table: %s", path);
  fclose(f);
  return rs;
}

static RowSet read_rows(const char *table, const Schema *s) {
  char *path = data_path(table);
  RowSet rs = read_rows_path(path, s);
  free(path);
  return rs;
}

static char *stage_rows(const char *table, const Schema *s, const RowSet *rs) {
  char *td = table_dir(table), *tmp = xasprintf("%s/.data.bdb.tmp", td);
  FILE *f = fopen(tmp, "wb");
  if (!f) die("open %s: %s", tmp, strerror(errno));
  write_magic(f); write_u32(f, 1); write_u32(f, (uint32_t)s->len); write_u32(f, (uint32_t)rs->len);
  for (size_t r = 0; r < rs->len; r++) for (size_t c = 0; c < s->len; c++) write_str(f, rs->rows[r][c]);
  sync_file(f, tmp);
  if (fclose(f) != 0) die("close %s: %s", tmp, strerror(errno));
  free(td);
  return tmp;
}

static void write_rows(const char *table, const Schema *s, const RowSet *rs) {
  char *path = data_path(table), *tmp = stage_rows(table, s, rs);
  WalEntry entry = {.target = path, .staged = tmp};
  commit_files(&entry, 1);
  free(tmp);
  free(path);
}

static int col_index(const Schema *s, const char *name) {
  for (size_t i = 0; i < s->len; i++) if (strcmp(s->cols[i].name, name) == 0) return (int)i;
  return -1;
}

static bool validate_type(const char *type, const char *val) {
  if (strcmp(type, "text") == 0 || strcmp(type, "string") == 0) return true;
  if (strcmp(type, "bool") == 0) return !strcmp(val, "true") || !strcmp(val, "false") || !strcmp(val, "1") || !strcmp(val, "0");
  char *end = NULL; errno = 0;
  if (strcmp(type, "int") == 0) { strtol(val, &end, 10); return errno == 0 && end && *end == 0; }
  if (strcmp(type, "real") == 0) { strtod(val, &end); return errno == 0 && end && *end == 0; }
  die("type inconnu: %s", type);
  return false;
}

static Assign parse_assign(const char *s) {
  const char *eq = strchr(s, '=');
  if (!eq) die("affectation attendue: COL=VALUE");
  Assign a = {.col = strndup(s, (size_t)(eq - s)), .val = xstrdup(eq + 1)};
  if (!a.col) die("out of memory");
  if (!is_name(a.col)) die("nom de colonne invalide: %s", a.col);
  return a;
}

static void free_assigns(Assign *a, size_t n) {
  for (size_t i = 0; i < n; i++) { free(a[i].col); free(a[i].val); }
  free(a);
}

static char *assignment_value(const char *col, Assign *a, size_t n) {
  for (size_t i = 0; i < n; i++) if (strcmp(a[i].col, col) == 0) return a[i].val;
  return NULL;
}

static bool row_matches(char **row, const Schema *s, const char *col, const char *val) {
  if (!col) return true;
  int idx = col_index(s, col);
  if (idx < 0) die("colonne inconnue: %s", col);
  return strcmp(row[idx], val) == 0;
}

static void require_unique_pk(const char *table, const Schema *s, const RowSet *rs) {
  if (s->pk_idx < 0) return;
  for (size_t r = 0; r < rs->len; r++) {
    for (size_t prev = 0; prev < r; prev++) {
      if (strcmp(rs->rows[prev][s->pk_idx], rs->rows[r][s->pk_idx]) == 0)
        die("%s: cle primaire dupliquee: %s", table, rs->rows[r][s->pk_idx]);
    }
  }
}

static void read_boot_id(char *out, size_t size) {
  out[0] = 0;
  FILE *f = fopen("/proc/sys/kernel/random/boot_id", "r");
  if (!f) return;
  if (fgets(out, (int)size, f)) out[strcspn(out, "\r\n")] = 0;
  fclose(f);
}

static void lock_db(void) {
  char *lock = xasprintf("%s/.lock", db_dir());
  char *owner = xasprintf("%s/owner", lock);
  char boot_id[64];
  read_boot_id(boot_id, sizeof(boot_id));
  for (int i = 0; i < 50; i++) {
    if (mkdir(lock, 0755) == 0) {
      FILE *f = fopen(owner, "w");
      if (!f) die("open lock owner: %s", strerror(errno));
      fprintf(f, "%ld %s\n", (long)getpid(), boot_id);
      sync_file(f, owner);
      fclose(f);
      free(owner);
      free(lock);
      return;
    }
    FILE *f = fopen(owner, "r");
    long pid = 0;
    char owner_boot_id[64] = "";
    if (f) {
      if (fscanf(f, "%ld %63s", &pid, owner_boot_id) < 1) pid = 0;
      fclose(f);
    }
    bool wrong_boot = boot_id[0] && strcmp(boot_id, owner_boot_id) != 0;
    bool dead_owner = pid <= 1 || pid == (long)getpid() ||
      (kill((pid_t)pid, 0) != 0 && errno == ESRCH);
    if (wrong_boot || dead_owner) {
      unlink(owner);
      rmdir(lock);
      continue;
    }
    usleep(100000);
  }
  free(owner);
  die("verrou occupe: %s", db_dir());
}

static void unlock_db(void) {
  char *lock = xasprintf("%s/.lock", db_dir());
  char *owner = xasprintf("%s/owner", lock);
  unlink(owner);
  rmdir(lock);
  free(owner);
  free(lock);
}

static void cmd_init(int argc, char **argv) {
  const char *dir = argc > 0 ? argv[0] : db_dir();
  char *tables = xasprintf("%s/tables", dir), *version = xasprintf("%s/VERSION", dir);
  mkdir_p(tables);
  FILE *f = fopen(version, "w");
  if (!f) die("open %s: %s", version, strerror(errno));
  fprintf(f, "%s\n", VERSION);
  sync_file(f, version);
  fclose(f);
  sync_dir(dir);
  printf("base initialisee: %s\n", dir);
  free(tables); free(version);
}

static void cmd_tables(void) {
  require_db();
  char *p = xasprintf("%s/tables", db_dir());
  DIR *d = opendir(p);
  if (!d) die("opendir %s: %s", p, strerror(errno));
  struct dirent *e;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char *td = xasprintf("%s/%s", p, e->d_name);
    if (exists_dir(td)) puts(e->d_name);
    free(td);
  }
  closedir(d); free(p);
}

static void validate_table(const char *table) {
  Schema s = load_schema(table);
  RowSet rs = read_rows(table, &s);
  for (size_t r = 0; r < rs.len; r++) {
    for (size_t c = 0; c < s.len; c++) {
      if (!validate_type(s.cols[c].type, rs.rows[r][c]))
        die("%s: valeur invalide ligne %zu colonne %s", table, r + 1, s.cols[c].name);
    }
  }
  require_unique_pk(table, &s, &rs);
  free_rowset(&rs, s.len);
  free_schema(&s);
}

static void validate_rows(const char *table, const Schema *s, const RowSet *rs) {
  for (size_t r = 0; r < rs->len; r++) {
    for (size_t c = 0; c < s->len; c++) {
      if (!validate_type(s->cols[c].type, rs->rows[r][c]))
        die("%s: valeur invalide ligne %zu colonne %s",
            table, r + 1, s->cols[c].name);
    }
  }
  require_unique_pk(table, s, rs);
}

static void cmd_check(int argc, char **argv) {
  require_db();
  if (argc > 1) die("usage: bdb check [TABLE]");
  if (argc == 1) {
    require_table(argv[0]);
    validate_table(argv[0]);
    printf("ok\t%s\n", argv[0]);
    return;
  }
  char *p = xasprintf("%s/tables", db_dir());
  DIR *d = opendir(p);
  if (!d) die("opendir %s: %s", p, strerror(errno));
  struct dirent *e;
  size_t count = 0;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char *td = xasprintf("%s/%s", p, e->d_name);
    if (exists_dir(td)) {
      validate_table(e->d_name);
      printf("ok\t%s\n", e->d_name);
      count++;
    }
    free(td);
  }
  closedir(d);
  free(p);
  printf("base saine: %zu table(s)\n", count);
}

static void cmd_schema(const char *table) {
  require_db(); require_table(table);
  Schema s = load_schema(table);
  for (size_t i = 0; i < s.len; i++) printf("%s\t%s\t%s\n", s.cols[i].name, s.cols[i].type, s.cols[i].pk ? "pk" : "");
  free_schema(&s);
}

static void cmd_create(int argc, char **argv) {
  if (argc < 2) die("usage: bdb create TABLE COL:TYPE[:pk]...");
  require_db();
  const char *table = argv[0];
  if (!is_name(table)) die("nom de table invalide: %s", table);
  char *td = table_dir(table);
  if (exists_dir(td)) die("table deja existante: %s", table);
  mkdir_p(td);

  Schema s = {.pk_idx = -1};
  s.len = (size_t)argc - 1;
  s.cols = calloc(s.len, sizeof(Column));
  if (!s.cols && s.len) die("out of memory");
  int pk_count = 0;
  for (int i = 1; i < argc; i++) {
    char *spec = xstrdup(argv[i]);
    char *col = strtok(spec, ":"), *typ = strtok(NULL, ":"), *flag = strtok(NULL, ":");
    if (!col || !typ || !is_name(col)) die("spec colonne invalide: %s", argv[i]);
    if (strcmp(typ, "text") && strcmp(typ, "string") && strcmp(typ, "int") && strcmp(typ, "real") && strcmp(typ, "bool")) die("type invalide pour %s: %s", col, typ);
    if (flag && strcmp(flag, "pk") == 0) { pk_count++; s.pk_idx = i - 1; }
    else if (flag) die("option de colonne inconnue: %s", flag);
    if (pk_count > 1) die("une seule cle primaire est supportee");
    s.cols[i - 1].name = xstrdup(col);
    s.cols[i - 1].type = xstrdup(typ);
    s.cols[i - 1].pk = flag && strcmp(flag, "pk") == 0;
    free(spec);
  }
  RowSet empty = {0};
  char *schema = schema_path(table), *data = data_path(table);
  char *schema_tmp = stage_schema(table, &s);
  char *data_tmp = stage_rows(table, &s, &empty);
  WalEntry entries[] = {
    {.target = schema, .staged = schema_tmp},
    {.target = data, .staged = data_tmp}
  };
  commit_files(entries, 2);
  free(schema_tmp);
  free(data_tmp);
  free(schema);
  free(data);
  free_schema(&s);
  free(td);
  printf("table creee: %s\n", table);
}

static void print_dump(const char *table, const char *where_col, const char *where_val) {
  Schema s = load_schema(table);
  RowSet rs = read_rows(table, &s);
  for (size_t i = 0; i < s.len; i++) { if (i) putchar('\t'); fputs(s.cols[i].name, stdout); }
  putchar('\n');
  for (size_t r = 0; r < rs.len; r++) {
    if (!row_matches(rs.rows[r], &s, where_col, where_val)) continue;
    for (size_t c = 0; c < s.len; c++) { if (c) putchar('\t'); fputs(rs.rows[r][c], stdout); }
    putchar('\n');
  }
  free_rowset(&rs, s.len);
  free_schema(&s);
}

static void cmd_select(int argc, char **argv) {
  if (argc != 1 && argc != 3) die("usage: bdb select TABLE [--where COL=VALUE]");
  require_db(); require_table(argv[0]);
  const char *where_col = NULL, *where_val = NULL;
  Assign where = {0};
  if (argc == 3) {
    if (strcmp(argv[1], "--where") != 0) die("clause attendue: --where COL=VALUE");
    where = parse_assign(argv[2]); where_col = where.col; where_val = where.val;
  }
  print_dump(argv[0], where_col, where_val);
  free(where.col); free(where.val);
}

static void cmd_insert(int argc, char **argv) {
  if (argc < 2) die("usage: bdb insert TABLE COL=VALUE...");
  require_db(); require_table(argv[0]);
  Schema s = load_schema(argv[0]);
  RowSet rs = read_rows(argv[0], &s);
  size_t an = (size_t)argc - 1;
  Assign *a = calloc(an, sizeof(Assign));
  if (!a) die("out of memory");
  for (size_t i = 0; i < an; i++) a[i] = parse_assign(argv[i + 1]);

  rs.rows = realloc(rs.rows, (rs.len + 1) * sizeof(char **));
  if (!rs.rows) die("out of memory");
  rs.rows[rs.len] = calloc(s.len, sizeof(char *));
  if (!rs.rows[rs.len]) die("out of memory");
  for (size_t c = 0; c < s.len; c++) {
    char *v = assignment_value(s.cols[c].name, a, an);
    if (!v) die("colonne manquante: %s", s.cols[c].name);
    if (!validate_type(s.cols[c].type, v)) die("valeur invalide pour %s (%s): %s", s.cols[c].name, s.cols[c].type, v);
    rs.rows[rs.len][c] = xstrdup(v);
  }
  rs.len++;
  require_unique_pk(argv[0], &s, &rs);
  write_rows(argv[0], &s, &rs);
  printf("ligne inseree: %s\n", argv[0]);
  free_assigns(a, an); free_rowset(&rs, s.len); free_schema(&s);
}

static void cmd_update(int argc, char **argv) {
  if (argc < 4 || strcmp(argv[1], "--where") != 0) die("usage: bdb update TABLE --where COL=VALUE COL=VALUE...");
  require_db(); require_table(argv[0]);
  Schema s = load_schema(argv[0]);
  RowSet rs = read_rows(argv[0], &s);
  Assign where = parse_assign(argv[2]);
  size_t an = (size_t)argc - 3, count = 0;
  Assign *a = calloc(an, sizeof(Assign));
  if (!a) die("out of memory");
  for (size_t i = 0; i < an; i++) a[i] = parse_assign(argv[i + 3]);
  for (size_t r = 0; r < rs.len; r++) {
    if (!row_matches(rs.rows[r], &s, where.col, where.val)) continue;
    count++;
    for (size_t c = 0; c < s.len; c++) {
      char *v = assignment_value(s.cols[c].name, a, an);
      if (!v) continue;
      if (!validate_type(s.cols[c].type, v)) die("valeur invalide pour %s (%s): %s", s.cols[c].name, s.cols[c].type, v);
      free(rs.rows[r][c]);
      rs.rows[r][c] = xstrdup(v);
    }
  }
  require_unique_pk(argv[0], &s, &rs);
  write_rows(argv[0], &s, &rs);
  printf("lignes modifiees: %zu\n", count);
  free_assigns(a, an); free(where.col); free(where.val); free_rowset(&rs, s.len); free_schema(&s);
}

static void cmd_delete(int argc, char **argv) {
  if (argc != 3 || strcmp(argv[1], "--where") != 0) die("usage: bdb delete TABLE --where COL=VALUE");
  require_db(); require_table(argv[0]);
  Schema s = load_schema(argv[0]);
  RowSet rs = read_rows(argv[0], &s), out = {0};
  Assign where = parse_assign(argv[2]);
  out.rows = calloc(rs.len, sizeof(char **));
  if (!out.rows && rs.len) die("out of memory");
  size_t count = 0;
  for (size_t r = 0; r < rs.len; r++) {
    if (row_matches(rs.rows[r], &s, where.col, where.val)) { count++; free_row(rs.rows[r], s.len); }
    else out.rows[out.len++] = rs.rows[r];
  }
  free(rs.rows);
  write_rows(argv[0], &s, &out);
  printf("lignes supprimees: %zu\n", count);
  free(where.col); free(where.val); free_rowset(&out, s.len); free_schema(&s);
}

static void cmd_drop(const char *table) {
  require_db(); require_table(table);
  char *td = table_dir(table);
  char *tables = xasprintf("%s/tables", db_dir());
  char *tombstone = xasprintf("%s/.drop-%s-%ld", tables, table, (long)getpid());
  if (rename(td, tombstone) != 0) die("drop %s: %s", table, strerror(errno));
  sync_dir(tables);
  char *schema = xasprintf("%s/schema.bdb", tombstone);
  char *data = xasprintf("%s/data.bdb", tombstone);
  unlink(schema);
  unlink(data);
  if (rmdir(tombstone) != 0) die("cleanup drop %s: %s", table, strerror(errno));
  sync_dir(tables);
  printf("table supprimee: %s\n", table);
  free(schema); free(data); free(tombstone); free(tables); free(td);
}

static void cmd_transact(int argc, char **argv) {
  if (argc < 1 || argc > 64)
    die("usage: bdb transact TABLE=DATA.bdb [TABLE=DATA.bdb ...]");

  WalEntry *entries = calloc((size_t)argc, sizeof(WalEntry));
  Schema *schemas = calloc((size_t)argc, sizeof(Schema));
  RowSet *rowsets = calloc((size_t)argc, sizeof(RowSet));
  char **tables = calloc((size_t)argc, sizeof(char *));
  char **targets = calloc((size_t)argc, sizeof(char *));
  char **staged = calloc((size_t)argc, sizeof(char *));
  if (!entries || !schemas || !rowsets || !tables || !targets || !staged)
    die("out of memory");

  for (int i = 0; i < argc; i++) {
    const char *eq = strchr(argv[i], '=');
    if (!eq || eq == argv[i] || !eq[1])
      die("transaction attend TABLE=DATA.bdb");
    tables[i] = strndup(argv[i], (size_t)(eq - argv[i]));
    if (!tables[i]) die("out of memory");
    if (!is_name(tables[i])) die("nom de table invalide: %s", tables[i]);
    for (int prev = 0; prev < i; prev++) {
      if (strcmp(tables[prev], tables[i]) == 0)
        die("table dupliquee dans la transaction: %s", tables[i]);
    }
    require_table(tables[i]);
    schemas[i] = load_schema(tables[i]);
    rowsets[i] = read_rows_path(eq + 1, &schemas[i]);
    validate_rows(tables[i], &schemas[i], &rowsets[i]);
    targets[i] = data_path(tables[i]);
    staged[i] = stage_rows(tables[i], &schemas[i], &rowsets[i]);
    entries[i].target = targets[i];
    entries[i].staged = staged[i];
  }

  commit_files(entries, (size_t)argc);
  for (int i = 0; i < argc; i++) {
    free(staged[i]);
    free(targets[i]);
    free_rowset(&rowsets[i], schemas[i].len);
    free_schema(&schemas[i]);
    free(tables[i]);
  }
  free(staged); free(targets); free(tables);
  free(rowsets); free(schemas); free(entries);
  printf("transaction validee: %d table(s)\n", argc);
}

static void usage(void) {
  puts("bdbc - moteur C natif pour bdb");
  puts("usage: bdb init|create|tables|schema|insert|select|dump|update|delete|drop|check|transact ...");
}

int main(int argc, char **argv) {
  if (argc < 2) { usage(); return 0; }
  const char *cmd = argv[1];
  if (strcmp(cmd, "version") == 0 || strcmp(cmd, "--version") == 0) { puts(VERSION); return 0; }
  bool init = !strcmp(cmd, "init");
  bool writes = !strcmp(cmd, "create") || !strcmp(cmd, "insert") ||
    !strcmp(cmd, "update") || !strcmp(cmd, "delete") || !strcmp(cmd, "drop") ||
    !strcmp(cmd, "transact");
  bool locked = false;
  if (!init) {
    require_db();
    char *wal = xasprintf("%s/WAL", db_dir());
    bool recovery_needed = access(wal, F_OK) == 0;
    free(wal);
    if (writes || recovery_needed) {
      lock_db();
      locked = true;
      recover_wal();
      cleanup_stale_files();
      if (!writes) {
        unlock_db();
        locked = false;
      }
    }
  }
  if (init) cmd_init(argc - 2, argv + 2);
  else if (strcmp(cmd, "create") == 0) cmd_create(argc - 2, argv + 2);
  else if (strcmp(cmd, "tables") == 0) cmd_tables();
  else if (strcmp(cmd, "schema") == 0) { if (argc != 3) die("usage: bdb schema TABLE"); cmd_schema(argv[2]); }
  else if (strcmp(cmd, "select") == 0 || strcmp(cmd, "dump") == 0) {
    if (argc == 3 && strcmp(cmd, "dump") == 0) { require_db(); require_table(argv[2]); print_dump(argv[2], NULL, NULL); }
    else cmd_select(argc - 2, argv + 2);
  }
  else if (strcmp(cmd, "insert") == 0) cmd_insert(argc - 2, argv + 2);
  else if (strcmp(cmd, "update") == 0) cmd_update(argc - 2, argv + 2);
  else if (strcmp(cmd, "delete") == 0) cmd_delete(argc - 2, argv + 2);
  else if (strcmp(cmd, "drop") == 0) { if (argc != 3) die("usage: bdb drop TABLE"); cmd_drop(argv[2]); }
  else if (strcmp(cmd, "check") == 0) cmd_check(argc - 2, argv + 2);
  else if (strcmp(cmd, "transact") == 0) cmd_transact(argc - 2, argv + 2);
  else {
    usage();
    if (locked) unlock_db();
    return 64;
  }
  if (locked) unlock_db();
  return 0;
}
