#ifndef __AF_RULE_CONFIG_H__
#define __AF_RULE_CONFIG_H__
#include "app_filter.h"
#include "af_utils.h"
#include "af_log.h"
void af_init_app_status(void);
int af_get_app_status(int appid);
int af_get_app_status_fast(int appid);
bool af_has_app_status(void);

#endif
