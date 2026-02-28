/*
 *  ltdl.h - ltdl stub for iOS
 */

#ifndef LTDL_H
#define LTDL_H

typedef void *lt_dlhandle;

int lt_dlinit(void);
int lt_dlexit(void);
int lt_dladdsearchdir(const char *search_dir);
lt_dlhandle lt_dlopen(const char *filename);
lt_dlhandle lt_dlopenext(const char *filename);
int lt_dlclose(lt_dlhandle handle);
void *lt_dlsym(lt_dlhandle handle, const char *name);
const char *lt_dlerror(void);

#endif /* LTDL_H */
