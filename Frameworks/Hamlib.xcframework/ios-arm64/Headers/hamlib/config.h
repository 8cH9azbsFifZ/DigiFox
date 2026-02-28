/* config.h for iOS port of Hamlib */

/* Frontend ABI version */
#define ABI_VERSION 4
#define ABI_REVISION 7
#define ABI_AGE 0
#define ABI_VERSION_MAJOR 4
#define ABI_VERSION_MINOR 7
#define ABI_VERSION_PATCH 1

/* Define to 1 if you have `alloca', as a function or macro. */
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1

/* iOS/Darwin does not have argz.h */
/* #undef HAVE_ARGZ_H */

/* Network headers available on iOS */
#define HAVE_ARPA_INET_H 1
#define HAVE_NETDB_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_SYS_SOCKET_H 1

/* Standard C/POSIX functions */
#define HAVE_ATEXIT 1
#define HAVE_CFMAKERAW 1
#define HAVE_DIRENT_H 1
#define HAVE_DLFCN_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_GAI_STRERROR 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETOPT 1
#define HAVE_GETOPT_H 1
#define HAVE_GETOPT_LONG 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_INTTYPES_H 1
#define HAVE_IOCTL 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMORY_H 1
#define HAVE_MEMSET 1
#define HAVE_SELECT 1
#define HAVE_SETITIMER 1
#define HAVE_SIGACTION 1
#define HAVE_SIGINFO_T 1
#define HAVE_SLEEP 1
#define HAVE_SNPRINTF 1
#define HAVE_SSIZE_T 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRCASECMP 1
#define HAVE_STRCHR 1
#define HAVE_STRDUP 1
#define HAVE_STRERROR 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_STRRCHR 1
#define HAVE_STRSTR 1
#define HAVE_STRTOL 1
#define HAVE_STRUCT_ADDRINFO 1
#define HAVE_STRUCT_TIMEZONE 1
#define HAVE_TERMIOS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_USLEEP 1
#define HAVE_VPRINTF 1
#define HAVE_GLOB_H 1
#define HAVE_PTHREAD 1
#define HAVE_CLOCK_GETTIME 1

/* iOS/Darwin specific */
#define HAVE_SYS_IOCCOM_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1

/* Not available on iOS */
/* #undef HAVE_DEV_PPBUS_PPBCONF_H */
/* #undef HAVE_DEV_PPBUS_PPI_H */
/* #undef HAVE_LINUX_IOCTL_H */
/* #undef HAVE_LINUX_PPDEV_H */
/* #undef HAVE_LINUX_HIDRAW_H */
/* #undef HAVE_LINUX_INPUT_H */
/* #undef HAVE_MALLOC_H */
/* #undef HAVE_SGTTY_H */
/* #undef HAVE_TERMIO_H */
/* #undef HAVE_VALUES_H */
/* #undef HAVE_LIBUSB */
/* #undef HAVE_LIBUSB_H */
/* #undef HAVE_WINBASE_H */
/* #undef HAVE_WINDOWS_H */
/* #undef HAVE_WINIOCTL_H */
/* #undef HAVE_WS2TCPIP_H */
/* #undef HAVE_SSLEEP */
/* #undef HAVE_XML2 */

/* Package info */
#define PACKAGE_BUGREPORT "hamlib-developer@lists.sourceforge.net"
#define PACKAGE_NAME "Hamlib"
#define PACKAGE_STRING "Hamlib 4.7.1"
#define PACKAGE_TARNAME "hamlib"
#define PACKAGE_URL "http://www.hamlib.org"
#define PACKAGE_VERSION "4.7.1"

/* Signal handling */
#define RETSIGTYPE void

/* Standard headers */
#define STDC_HEADERS 1
#define TIME_WITH_SYS_TIME 1

/* Libtool */
#define LT_OBJDIR ".libs/"

/* POSIX extensions */
#ifndef _ALL_SOURCE
# define _ALL_SOURCE 1
#endif
#ifndef _GNU_SOURCE
# define _GNU_SOURCE 1
#endif
#ifndef _POSIX_PTHREAD_SEMANTICS
# define _POSIX_PTHREAD_SEMANTICS 1
#endif
#ifndef __EXTENSIONS__
# define __EXTENSIONS__ 1
#endif

/* Hamlib module directory - not used in static build */
#define HAMLIB_MODULE_DIR "."

/* We build statically, no dynamic loading of backends */
/* #undef HAVE_LTDL_H */
