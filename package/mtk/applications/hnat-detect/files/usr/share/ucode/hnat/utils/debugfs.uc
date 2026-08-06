/*
 * HNAT debugfs topology and hook helpers.
 * 
 * Copyright (C) 2026  chasey-dev <ellenyoung0912@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
'use strict';

import * as fs from 'fs'; 
import { log, read_first_line } from 'hnat.utils.common';

const HNAT_PATH = '/sys/kernel/debug/hnat';

const HNAT_PATH_HOOK_TOOGLE = `${HNAT_PATH}/hook_toggle`;
const HNAT_PATH_TOPOLOGY = `${HNAT_PATH}/hnat_topology`;

const HNAT_PATH_PPD_IF = `${HNAT_PATH}/hnat_ppd_if`;
const HNAT_PATH_WAN_IF = `${HNAT_PATH}/hnat_wan_if`;
const HNAT_PATH_LAN_IF = `${HNAT_PATH}/hnat_lan_if`;
const HNAT_PATH_LAN2_IF = `${HNAT_PATH}/hnat_lan2_if`;

export function is_hnat_present() {
    return fs.access(HNAT_PATH);
};

const rw = (path) => {
    let _path = path;
    return {
        read: () => read_first_line(_path),
        write: (value) => {
            if (value == null || value == '')
                return false;

            /* fs.writefile returns written bytes or null on error */
            let n = fs.writefile(_path, value + '\n');
            if (n == null) {
                log.error(`write failed: ${_path} err= ${fs.error()}`);
                return false;
            }

            log.info(`write: ${_path} = ${value}`);
            return true;
        }
    }
};

const ro = (path) => {
    let _path = path;
    return {
        read: () => read_first_line(_path)
    }
};

const rw_line = (path) => {
    let _path = path;
    return {
        read: () => fs.readfile(_path),
        write: (value) => {
            if (value == null || value == '')
                return false;

            /* fs.writefile returns written bytes or null on error */
            let n = fs.writefile(_path, value + '\n');
            if (n == null) {
                log.error(`write failed: ${_path} err= ${fs.error()}`);
                return false;
            }

            log.info(`write: ${_path} = ${value}`);
            return true;
        }
    }
};

export const hook_toggle = rw(HNAT_PATH_HOOK_TOOGLE);
export const topology = rw_line(HNAT_PATH_TOPOLOGY);

/* Compatibility reads for diagnostics; the kernel exposes these as read-only. */
export const ppd = ro(HNAT_PATH_PPD_IF);
export const wan = ro(HNAT_PATH_WAN_IF);
export const lan = ro(HNAT_PATH_LAN_IF);
export const lan2 = ro(HNAT_PATH_LAN2_IF);
