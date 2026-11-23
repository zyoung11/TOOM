/* compat_shim.c - glibc symbol version compatibility. The static
 * libraries are compiled against a new glibc whose headers bind these
 * calls to fresh symbol versions. Every entry point is defined
 * locally so the calls never reach a versioned glibc symbol. The
 * float math forwards to the double precision functions whose symbol
 * versions never changed, so nothing here can resolve back to itself.
 */
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>

__asm__(".symver shim_strtol, strtol@GLIBC_2.2.5");
__asm__(".symver shim_strtoul, strtoul@GLIBC_2.2.5");
__asm__(".symver shim_strtoll, strtoll@GLIBC_2.2.5");
__asm__(".symver shim_strtoull, strtoull@GLIBC_2.2.5");
__asm__(".symver shim_vsscanf, vsscanf@GLIBC_2.2.5");

extern long shim_strtol(const char *, char **, int);
extern unsigned long shim_strtoul(const char *, char **, int);
extern long long shim_strtoll(const char *, char **, int);
extern unsigned long long shim_strtoull(const char *, char **, int);
extern int shim_vsscanf(const char *, const char *, va_list);

float log10f(float x) {
	return (float)log10((double)x);
}

float atan2f(float y, float x) {
	return (float)atan2((double)y, (double)x);
}

float sqrtf(float x) {
	return __builtin_sqrtf(x);
}

double cosh(double x) {
	return (exp(x) + exp(-x)) * 0.5;
}

double sinh(double x) {
	return (exp(x) - exp(-x)) * 0.5;
}

long __isoc23_strtol(const char *n, char **e, int b) {
	return shim_strtol(n, e, b);
}

unsigned long __isoc23_strtoul(const char *n, char **e, int b) {
	return shim_strtoul(n, e, b);
}

long long __isoc23_strtoll(const char *n, char **e, int b) {
	return shim_strtoll(n, e, b);
}

unsigned long long __isoc23_strtoull(const char *n, char **e, int b) {
	return shim_strtoull(n, e, b);
}

int __isoc23_sscanf(const char *s, const char *f, ...) {
	va_list ap;
	int r;
	va_start(ap, f);
	r = shim_vsscanf(s, f, ap);
	va_end(ap);
	return r;
}

uint32_t arc4random(void) {
	uint32_t v = 0;
	if ((long)syscall(SYS_getrandom, &v, sizeof v, 0) != (long)sizeof v) {
		v = (uint32_t)(uintptr_t)&v ^ ((uint32_t)syscall(SYS_getpid) << 16);
	}
	return v;
}
