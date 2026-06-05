#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define VERSION "0.2.0-c"
#define BDB_MAGIC "BDB1"

typedef struct {
  char *name;
  char *type;
  bool pk;
} Column;

typedef struct {
  Column *cols;
  size_t len;
  int pk_idx;
} Schema;

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

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

static char *table_dir(const char *table) {
  return xasprintf("%s/tables/%s", db_dir(), table);
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

static void mkdir_p(const char *path) {
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof(tmp), "%s", path);
  for (char *p = tmp + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      mkdir(tmp, 0755);
      *p = '/';
    }
  }
  if (mkdir(tmp, 0755) && errno != EEXIST) die("mkdir %s: %s", path, strerror(errno));
}

static int b64_index(char c) {
  const char *p = strchr(b64, c);
  return p ? (int)(p - b64) : -1;
}

static char *b64_decode(const char *in) {
  size_t cap = strlen(in) * 3 / 4 + 4, len = 0;
  unsigned char *out = malloc(cap);
  if (!out) die("out of memory");
  int acc = 0, bits = 0;
  for (size_t i = 0; in[i]; i++) {
    if (in[i] == '=') break;
    int v = b64_index(in[i]);
    if (v < 0) continue;
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[len++] = (unsigned char)((acc >> bits) & 0xff);
    }
  }
  out[len] = 0;
  return (char *)out;
}

static char *b64_encode(const char *in) {
  size_t n = strlen(in), cap = ((n + 2) / 3) * 4 + 1, j = 0;
  char *out = malloc(cap);
  if (!out) die("out of memory");
  for (size_t i = 0; i < n; i += 3) {
    unsigned int b0 = (unsigned char)in[i];
    unsigned int b1 = (i + 1 < n) ? (unsigned char)in[i + 1] : 0;
    unsigned int b2 = (i + 2 < n) ? (unsigned char)in[i + 2] : 0;
    unsigned int x = (b0 << 16) | (b1 << 8) | b2;
    out[j++] = b64[(x >> 18) & 63];
    out[j++] = b64[(x >> 12) & 63];
    out[j++] = (i + 1 < n) ? b64[(x >> 6) & 63] : '=';
    out[j++] = (i + 2 < n) ? b64[x & 63] : '=';
  }
  out[j] = 0;
  return out;
}

static char **split_tab(const char *line, size_t *count) {
  char *copy = xstrdup(line);
  size_t cap = 8, n = 0;
  char **v = calloc(cap, sizeof(char *));
  if (!v) die("out of memory");
  char *save = NULL, *tok = strtok_r(copy, "\t\n", &save);
  while (tok) {
    if (n == cap) {
      cap *= 2;
      v = realloc(v, cap * sizeof(char *));
      if (!v) die("out of memory");
    }
    v[n++] = xstrdup(tok);
    tok = strtok_r(NULL, "\t\n", &save);
  }
  free(copy);
  *count = n;
  return v;
}

static void free_vec(char **v, size_t n) {
  for (size_t i = 0; i < n; i++) free(v[i]);
  free(v);
}

static Schema load_schema(const char *table) {
  char *path = xasprintf("%s/schema.tsv", table_dir(table));
  FILE *f = fopen(path, "r");
  free(path);
  if (!f) die("schema introuvable: %s", table);

  Schema s = {0};
  s.pk_idx = -1;
  char *line = NULL;
  size_t cap = 0;
  while (getline(&line, &cap, f) != -1) {
    size_t n = 0;
    char **fields = split_tab(line, &n);
    if (n >= 2) {
      s.cols = realloc(s.cols, (s.len + 1) * sizeof(Column));
      if (!s.cols) die("out of memory");
      s.cols[s.len].name = xstrdup(fields[0]);
      s.cols[s.len].type = xstrdup(fields[1]);
      s.cols[s.len].pk = (n >= 3 && strcmp(fields[2], "pk") == 0);
      if (s.cols[s.len].pk) s.pk_idx = (int)s.len;
      s.len++;
    }
    free_vec(fields, n);
  }
  free(line);
  fclose(f);
  return s;
}

static void free_schema(Schema *s) {
  for (size_t i = 0; i < s->len; i++) {
    free(s->cols[i].name);
    free(s->cols[i].type);
  }
  free(s->cols);
}

static int col_index(const Schema *s, const char *name) {
  for (size_t i = 0; i < s->len; i++) {
    if (strcmp(s->cols[i].name, name) == 0) return (int)i;
  }
  return -1;
}

static bool validate_type(const char *type, const char *val) {
  if (strcmp(type, "text") == 0 || strcmp(type, "string") == 0) return true;
  if (strcmp(type, "bool") == 0) {
    return strcmp(val, "true") == 0 || strcmp(val, "false") == 0 ||
           strcmp(val, "1") == 0 || strcmp(val, "0") == 0;
  }
  char *end = NULL;
  errno = 0;
  if (strcmp(type, "int") == 0) {
    strtol(val, &end, 10);
    return errno == 0 && end && *end == 0;
  }
  if (strcmp(type, "real") == 0) {
    strtod(val, &end);
    return errno == 0 && end && *end == 0;
  }
  die("type inconnu: %s", type);
  return false;
}

typedef struct {
  char *col;
  char *val;
} Assign;

static Assign parse_assign(const char *s) {
  const char *eq = strchr(s, '=');
  if (!eq) die("affectation attendue: COL=VALUE");
  Assign a;
  a.col = strndup(s, (size_t)(eq - s));
  a.val = xstrdup(eq + 1);
  if (!a.col) die("out of memory");
  if (!is_name(a.col)) die("nom de colonne invalide: %s", a.col);
  return a;
}

static char *assignment_value(const char *col, Assign *a, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (strcmp(a[i].col, col) == 0) return a[i].val;
  }
  return NULL;
}

static void free_assigns(Assign *a, size_t n) {
  for (size_t i = 0; i < n; i++) {
    free(a[i].col);
    free(a[i].val);
  }
  free(a);
}

static char **decode_row(const char *line, const Schema *s) {
  size_t n = 0;
  char **enc = split_tab(line, &n);
  char **dec = calloc(s->len, sizeof(char *));
  if (!dec) die("out of memory");
  for (size_t i = 0; i < s->len; i++) {
    dec[i] = b64_decode(i < n ? enc[i] : "");
  }
  free_vec(enc, n);
  return dec;
}

static void free_row(char **row, size_t n) {
  for (size_t i = 0; i < n; i++) free(row[i]);
  free(row);
}

static bool row_matches(char **row, const Schema *s, const char *col, const char *val) {
  if (!col) return true;
  int idx = col_index(s, col);
  if (idx < 0) die("colonne inconnue: %s", col);
  return strcmp(row[idx], val) == 0;
}

static char *data_path(const char *table) {
  return xasprintf("%s/data.tsv", table_dir(table));
}

static char *native_data_path(const char *table) {
  return xasprintf("%s/data.bdb", table_dir(table));
}

static bool exists_file(const char *p) {
  struct stat st;
  return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static void write_u32(FILE *f, uint32_t v) {
  unsigned char b[4] = {
    (unsigned char)(v & 255),
    (unsigned char)((v >> 8) & 255),
    (unsigned char)((v >> 16) & 255),
    (unsigned char)((v >> 24) & 255)
  };
  if (fwrite(b, 1, sizeof(b), f) != sizeof(b)) die("write failed");
}

static void write_str(FILE *f, const char *s) {
  size_t n = strlen(s);
  if (n > UINT32_MAX) die("field too large");
  write_u32(f, (uint32_t)n);
  if (n && fwrite(s, 1, n, f) != n) die("write failed");
}

static uint32_t read_u32(FILE *f) {
  unsigned char b[4];
  if (fread(b, 1, sizeof(b), f) != sizeof(b)) die("native read failed");
  return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static char *read_str(FILE *f) {
  uint32_t n = read_u32(f);
  char *s = calloc((size_t)n + 1, 1);
  if (!s) die("out of memory");
  if (n && fread(s, 1, n, f) != n) die("native read failed");
  return s;
}

static void read_magic(FILE *f, const char *path) {
  char magic[4];
  if (fread(magic, 1, 4, f) != 4 || memcmp(magic, BDB_MAGIC, 4) != 0) {
    die("format natif invalide: %s", path);
  }
}

static void pack_schema_file(const char *table, const Schema *s) {
  char *td = table_dir(table);
  char *path = xasprintf("%s/schema.bdb", td);
  char *tmp = xasprintf("%s/.schema.bdb.tmp", td);
  FILE *f = fopen(tmp, "wb");
  if (!f) die("open %s: %s", tmp, strerror(errno));

  if (fwrite(BDB_MAGIC, 1, 4, f) != 4) die("write failed");
  write_u32(f, 1);
  write_u32(f, (uint32_t)s->len);
  write_u32(f, s->pk_idx < 0 ? UINT32_MAX : (uint32_t)s->pk_idx);
  for (size_t i = 0; i < s->len; i++) {
    write_str(f, s->cols[i].name);
    write_str(f, s->cols[i].type);
    write_u32(f, s->cols[i].pk ? 1 : 0);
  }
  fclose(f);
  if (rename(tmp, path) != 0) die("rename %s: %s", path, strerror(errno));
  free(tmp);
  free(path);
  free(td);
}

static void pack_data_file(const char *table, const Schema *s) {
  char *td = table_dir(table);
  char *src = data_path(table);
  char *path = xasprintf("%s/data.bdb", td);
  char *tmp = xasprintf("%s/.data.bdb.tmp", td);
  FILE *in = fopen(src, "r");
  FILE *out = fopen(tmp, "wb");
  if (!in || !out) die("pack open: %s", strerror(errno));

  if (fwrite(BDB_MAGIC, 1, 4, out) != 4) die("write failed");
  write_u32(out, 1);
  write_u32(out, (uint32_t)s->len);
  long row_count_pos = ftell(out);
  write_u32(out, 0);

  char *line = NULL;
  size_t cap = 0, rows = 0;
  while (getline(&line, &cap, in) != -1) {
    if (line[0] == '\n' || line[0] == 0) continue;
    char **row = decode_row(line, s);
    for (size_t i = 0; i < s->len; i++) write_str(out, row[i]);
    free_row(row, s->len);
    rows++;
  }
  free(line);
  fseek(out, row_count_pos, SEEK_SET);
  write_u32(out, (uint32_t)rows);
  fclose(in);
  fclose(out);
  if (rename(tmp, path) != 0) die("rename %s: %s", path, strerror(errno));
  free(tmp);
  free(path);
  free(src);
  free(td);
}

static void pack_table(const char *table) {
  require_table(table);
  Schema s = load_schema(table);
  pack_schema_file(table, &s);
  pack_data_file(table, &s);
  free_schema(&s);
}

static void lock_db(void) {
  char *lock = xasprintf("%s/.lock", db_dir());
  for (int i = 0; i < 50; i++) {
    if (mkdir(lock, 0755) == 0) {
      free(lock);
      return;
    }
    usleep(100000);
  }
  die("verrou occupe: %s", db_dir());
}

static void unlock_db(void) {
  char *lock = xasprintf("%s/.lock", db_dir());
  rmdir(lock);
  free(lock);
}

static void cmd_init(int argc, char **argv) {
  const char *dir = argc > 0 ? argv[0] : db_dir();
  char *tables = xasprintf("%s/tables", dir);
  mkdir_p(tables);
  free(tables);
  char *version = xasprintf("%s/VERSION", dir);
  FILE *f = fopen(version, "w");
  if (!f) die("open %s: %s", version, strerror(errno));
  fprintf(f, "%s\n", VERSION);
  fclose(f);
  printf("base initialisee: %s\n", dir);
  free(version);
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
  closedir(d);
  free(p);
}

static void cmd_schema(const char *table) {
  require_db();
  require_table(table);
  char *p = xasprintf("%s/schema.tsv", table_dir(table));
  FILE *f = fopen(p, "r");
  if (!f) die("open %s: %s", p, strerror(errno));
  char *line = NULL;
  size_t cap = 0;
  while (getline(&line, &cap, f) != -1) fputs(line, stdout);
  free(line);
  fclose(f);
  free(p);
}

static void cmd_create(int argc, char **argv) {
  if (argc < 2) die("usage: bdb create TABLE COL:TYPE[:pk]...");
  require_db();
  const char *table = argv[0];
  if (!is_name(table)) die("nom de table invalide: %s", table);
  char *td = table_dir(table);
  if (exists_dir(td)) die("table deja existante: %s", table);
  mkdir_p(td);
  char *schema = xasprintf("%s/schema.tsv", td);
  char *data = xasprintf("%s/data.tsv", td);
  FILE *sf = fopen(schema, "w");
  FILE *df = fopen(data, "w");
  if (!sf || !df) die("create table files: %s", strerror(errno));
  int pk_count = 0;
  for (int i = 1; i < argc; i++) {
    char *spec = xstrdup(argv[i]);
    char *col = strtok(spec, ":");
    char *typ = strtok(NULL, ":");
    char *flag = strtok(NULL, ":");
    if (!col || !typ || !is_name(col)) die("spec colonne invalide: %s", argv[i]);
    if (strcmp(typ, "text") && strcmp(typ, "string") && strcmp(typ, "int") && strcmp(typ, "real") && strcmp(typ, "bool"))
      die("type invalide pour %s: %s", col, typ);
    if (flag && strcmp(flag, "pk") == 0) pk_count++;
    else if (flag) die("option de colonne inconnue: %s", flag);
    if (pk_count > 1) die("une seule cle primaire est supportee");
    fprintf(sf, "%s\t%s\t%s\n", col, typ, flag ? flag : "");
    free(spec);
  }
  fclose(sf);
  fclose(df);
  pack_table(table);
  printf("table creee: %s\n", table);
  free(schema);
  free(data);
  free(td);
}

static void print_dump(const char *table, const char *where_col, const char *where_val) {
  Schema s = load_schema(table);
  for (size_t i = 0; i < s.len; i++) {
    if (i) putchar('\t');
    fputs(s.cols[i].name, stdout);
  }
  putchar('\n');

  char *native = native_data_path(table);
  if (exists_file(native)) {
    FILE *f = fopen(native, "rb");
    if (!f) die("open %s: %s", native, strerror(errno));
    read_magic(f, native);
    uint32_t version = read_u32(f);
    uint32_t cols = read_u32(f);
    uint32_t rows = read_u32(f);
    if (version != 1 || cols != s.len) die("format natif incompatible: %s", native);
    for (uint32_t r = 0; r < rows; r++) {
      char **row = calloc(s.len, sizeof(char *));
      if (!row) die("out of memory");
      for (size_t i = 0; i < s.len; i++) row[i] = read_str(f);
      if (row_matches(row, &s, where_col, where_val)) {
        for (size_t i = 0; i < s.len; i++) {
          if (i) putchar('\t');
          fputs(row[i], stdout);
        }
        putchar('\n');
      }
      free_row(row, s.len);
    }
    fclose(f);
    free(native);
    free_schema(&s);
    return;
  }
  free(native);

  char *p = data_path(table);
  FILE *f = fopen(p, "r");
  if (!f) die("open %s: %s", p, strerror(errno));
  char *line = NULL;
  size_t cap = 0;
  while (getline(&line, &cap, f) != -1) {
    if (line[0] == '\n' || line[0] == 0) continue;
    char **row = decode_row(line, &s);
    if (row_matches(row, &s, where_col, where_val)) {
      for (size_t i = 0; i < s.len; i++) {
        if (i) putchar('\t');
        fputs(row[i], stdout);
      }
      putchar('\n');
    }
    free_row(row, s.len);
  }
  free(line);
  fclose(f);
  free(p);
  free_schema(&s);
}

static void cmd_select(int argc, char **argv) {
  if (argc != 1 && argc != 3) die("usage: bdb select TABLE [--where COL=VALUE]");
  require_db();
  require_table(argv[0]);
  const char *where_col = NULL, *where_val = NULL;
  Assign where = {0};
  if (argc == 3) {
    if (strcmp(argv[1], "--where") != 0) die("clause attendue: --where COL=VALUE");
    where = parse_assign(argv[2]);
    where_col = where.col;
    where_val = where.val;
  }
  print_dump(argv[0], where_col, where_val);
  free(where.col);
  free(where.val);
}

static void cmd_insert(int argc, char **argv) {
  if (argc < 2) die("usage: bdb insert TABLE COL=VALUE...");
  require_db();
  require_table(argv[0]);
  Schema s = load_schema(argv[0]);
  size_t an = (size_t)argc - 1;
  Assign *a = calloc(an, sizeof(Assign));
  if (!a) die("out of memory");
  for (size_t i = 0; i < an; i++) a[i] = parse_assign(argv[i + 1]);
  char *p = data_path(argv[0]);
  FILE *f = fopen(p, "a");
  if (!f) die("open %s: %s", p, strerror(errno));
  for (size_t i = 0; i < s.len; i++) {
    char *v = assignment_value(s.cols[i].name, a, an);
    if (!v) die("colonne manquante: %s", s.cols[i].name);
    if (!validate_type(s.cols[i].type, v)) die("valeur invalide pour %s (%s): %s", s.cols[i].name, s.cols[i].type, v);
    char *enc = b64_encode(v);
    if (i) fputc('\t', f);
    fputs(enc, f);
    free(enc);
  }
  fputc('\n', f);
  fclose(f);
  pack_table(argv[0]);
  printf("ligne inseree: %s\n", argv[0]);
  free(p);
  free_assigns(a, an);
  free_schema(&s);
}

static void cmd_update(int argc, char **argv) {
  if (argc < 4 || strcmp(argv[1], "--where") != 0) die("usage: bdb update TABLE --where COL=VALUE COL=VALUE...");
  require_db();
  require_table(argv[0]);
  Schema s = load_schema(argv[0]);
  Assign where = parse_assign(argv[2]);
  size_t an = (size_t)argc - 3;
  Assign *a = calloc(an, sizeof(Assign));
  if (!a) die("out of memory");
  for (size_t i = 0; i < an; i++) a[i] = parse_assign(argv[i + 3]);
  char *p = data_path(argv[0]);
  char *tmp = xasprintf("%s/update.%ld.tmp", db_dir(), (long)getpid());
  FILE *in = fopen(p, "r");
  FILE *out = fopen(tmp, "w");
  if (!in || !out) die("update open: %s", strerror(errno));
  char *line = NULL;
  size_t cap = 0, count = 0;
  while (getline(&line, &cap, in) != -1) {
    if (line[0] == '\n' || line[0] == 0) continue;
    char **row = decode_row(line, &s);
    if (row_matches(row, &s, where.col, where.val)) {
      count++;
      for (size_t i = 0; i < s.len; i++) {
        char *nv = assignment_value(s.cols[i].name, a, an);
        const char *v = nv ? nv : row[i];
        if (!validate_type(s.cols[i].type, v)) die("valeur invalide pour %s (%s): %s", s.cols[i].name, s.cols[i].type, v);
        char *enc = b64_encode(v);
        if (i) fputc('\t', out);
        fputs(enc, out);
        free(enc);
      }
      fputc('\n', out);
    } else {
      fputs(line, out);
    }
    free_row(row, s.len);
  }
  free(line);
  fclose(in);
  fclose(out);
  if (rename(tmp, p) != 0) die("rename: %s", strerror(errno));
  pack_table(argv[0]);
  printf("lignes modifiees: %zu\n", count);
  free(tmp);
  free(p);
  free_assigns(a, an);
  free(where.col);
  free(where.val);
  free_schema(&s);
}

static void cmd_delete(int argc, char **argv) {
  if (argc != 3 || strcmp(argv[1], "--where") != 0) die("usage: bdb delete TABLE --where COL=VALUE");
  require_db();
  require_table(argv[0]);
  Schema s = load_schema(argv[0]);
  Assign where = parse_assign(argv[2]);
  char *p = data_path(argv[0]);
  char *tmp = xasprintf("%s/delete.%ld.tmp", db_dir(), (long)getpid());
  FILE *in = fopen(p, "r");
  FILE *out = fopen(tmp, "w");
  if (!in || !out) die("delete open: %s", strerror(errno));
  char *line = NULL;
  size_t cap = 0, count = 0;
  while (getline(&line, &cap, in) != -1) {
    if (line[0] == '\n' || line[0] == 0) continue;
    char **row = decode_row(line, &s);
    if (row_matches(row, &s, where.col, where.val)) count++;
    else fputs(line, out);
    free_row(row, s.len);
  }
  free(line);
  fclose(in);
  fclose(out);
  if (rename(tmp, p) != 0) die("rename: %s", strerror(errno));
  pack_table(argv[0]);
  printf("lignes supprimees: %zu\n", count);
  free(tmp);
  free(p);
  free(where.col);
  free(where.val);
  free_schema(&s);
}

static void cmd_drop(const char *table) {
  require_db();
  require_table(table);
  char *td = table_dir(table);
  char *schema = xasprintf("%s/schema.tsv", td);
  char *data = xasprintf("%s/data.tsv", td);
  unlink(schema);
  unlink(data);
  if (rmdir(td) != 0) die("drop %s: %s", table, strerror(errno));
  printf("table supprimee: %s\n", table);
  free(schema);
  free(data);
  free(td);
}

static void cmd_pack(int argc, char **argv) {
  require_db();
  if (argc > 1) die("usage: bdb pack [TABLE|--all]");
  if (argc == 1 && strcmp(argv[0], "--all") != 0) {
    pack_table(argv[0]);
    printf("table packed: %s\n", argv[0]);
    return;
  }

  char *p = xasprintf("%s/tables", db_dir());
  DIR *d = opendir(p);
  if (!d) die("opendir %s: %s", p, strerror(errno));
  struct dirent *e;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char *td = xasprintf("%s/%s", p, e->d_name);
    if (exists_dir(td)) {
      pack_table(e->d_name);
      printf("table packed: %s\n", e->d_name);
    }
    free(td);
  }
  closedir(d);
  free(p);
}

static void usage(void) {
  puts("bdbc - moteur C pour bdb");
  puts("usage: bdb init|create|tables|schema|insert|select|dump|update|delete|drop|pack ...");
}

int main(int argc, char **argv) {
  if (argc < 2) {
    usage();
    return 0;
  }
  const char *cmd = argv[1];
  if (strcmp(cmd, "version") == 0 || strcmp(cmd, "--version") == 0) {
    puts(VERSION);
    return 0;
  }
  bool writes = !strcmp(cmd, "init") || !strcmp(cmd, "create") || !strcmp(cmd, "insert") ||
                !strcmp(cmd, "update") || !strcmp(cmd, "delete") || !strcmp(cmd, "drop") ||
                !strcmp(cmd, "pack");
  if (writes) lock_db();
  if (strcmp(cmd, "init") == 0) cmd_init(argc - 2, argv + 2);
  else if (strcmp(cmd, "create") == 0) cmd_create(argc - 2, argv + 2);
  else if (strcmp(cmd, "tables") == 0) cmd_tables();
  else if (strcmp(cmd, "schema") == 0) {
    if (argc != 3) die("usage: bdb schema TABLE");
    cmd_schema(argv[2]);
  } else if (strcmp(cmd, "select") == 0 || strcmp(cmd, "dump") == 0) {
    if (argc == 3 && strcmp(cmd, "dump") == 0) {
      require_db();
      require_table(argv[2]);
      print_dump(argv[2], NULL, NULL);
    } else {
      cmd_select(argc - 2, argv + 2);
    }
  } else if (strcmp(cmd, "insert") == 0) cmd_insert(argc - 2, argv + 2);
  else if (strcmp(cmd, "update") == 0) cmd_update(argc - 2, argv + 2);
  else if (strcmp(cmd, "delete") == 0) cmd_delete(argc - 2, argv + 2);
  else if (strcmp(cmd, "drop") == 0) {
    if (argc != 3) die("usage: bdb drop TABLE");
    cmd_drop(argv[2]);
  }
  else if (strcmp(cmd, "pack") == 0) {
    cmd_pack(argc - 2, argv + 2);
  } else {
    usage();
    if (writes) unlock_db();
    return 64;
  }
  if (writes) unlock_db();
  return 0;
}
