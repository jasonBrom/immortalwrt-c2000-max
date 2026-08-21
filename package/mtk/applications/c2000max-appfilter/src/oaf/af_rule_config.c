#include <linux/init.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/version.h>
#include "cJSON.h"
#include "app_filter.h"
#include "af_utils.h"
#include "af_log.h"
#include "af_config.h"
#include "af_rule_config.h"

DEFINE_RWLOCK(af_rule_lock);

#define af_rule_read_lock() read_lock_bh(&af_rule_lock);
#define af_rule_read_unlock() read_unlock_bh(&af_rule_lock);
#define af_rule_write_lock() write_lock_bh(&af_rule_lock);
#define af_rule_write_unlock() write_unlock_bh(&af_rule_lock);

extern u_int32_t g_update_jiffies;

char g_app_id_array[AF_MAX_APP_TYPE_NUM][AF_MAX_APP_ID_NUM] = {0};
static atomic_t af_active_app_count = ATOMIC_INIT(0);


static int af_change_app_status(cJSON *data_obj, int status)
{
	int i;
	int id;
	int type;
	cJSON *appid_arr = NULL;
	if (!data_obj)
	{
		AF_ERROR("data obj is null\n");
		return -1;
	}
	appid_arr = cJSON_GetObjectItem(data_obj, "apps");
	if (!appid_arr)
	{
		AF_ERROR("apps obj is null\n");
		return -1;
	}
	for (i = 0; i < cJSON_GetArraySize(appid_arr); i++)
	{
		cJSON *appid_obj = cJSON_GetArrayItem(appid_arr, i);
		if (!appid_obj)
			return -1;
		if (!af_appid_valid(appid_obj->valueint)) {
			AF_ERROR("invalid appid %d\n", appid_obj->valueint);
			return -1;
		}
		id = AF_APP_ID_INDEX(appid_obj->valueint);
		type = AF_APP_TYPE_INDEX(appid_obj->valueint);
		af_rule_write_lock();
		if (g_app_id_array[type][id] != status) {
			if (status)
				atomic_inc(&af_active_app_count);
			else
				atomic_dec(&af_active_app_count);
			g_app_id_array[type][id] = status;
		}
		af_rule_write_unlock();
	}

	return 0;
}



void af_init_app_status(void)
{
	af_rule_write_lock();
	memset(g_app_id_array, 0, sizeof(g_app_id_array));
	atomic_set(&af_active_app_count, 0);
	af_rule_write_unlock();
}
int af_get_app_status(int appid)
{
	int status = 0;
	int id;
	int type;

	if (!af_appid_valid(appid))
		return AF_FALSE;

	id = AF_APP_ID_INDEX(appid);
	type = AF_APP_TYPE_INDEX(appid);
	af_rule_read_lock();
	status = g_app_id_array[type][id];
	af_rule_read_unlock();
	return status;
}

/* Packet classification only needs a current priority hint.  A byte-sized
 * READ_ONCE is sufficient here: configuration writes are atomic, and a rule
 * update racing one packet may at worst defer the fast-path match to the next
 * payload.  The verdict path still uses the locked accessor above. */
int af_get_app_status_fast(int appid)
{
	int id;
	int type;

	if (!af_appid_valid(appid))
		return AF_FALSE;
	id = AF_APP_ID_INDEX(appid);
	type = AF_APP_TYPE_INDEX(appid);
	return READ_ONCE(g_app_id_array[type][id]);
}

bool af_has_app_status(void)
{
	return atomic_read(&af_active_app_count) > 0;
}

int af_config_add_appid(cJSON *data)
{
	return af_change_app_status(data, 1);
}

int af_config_del_appid(cJSON *data)
{
	return af_change_app_status(data, 0);
}

int af_config_clean_appid(cJSON *data)
{
	af_init_app_status();
	return 0;
}
