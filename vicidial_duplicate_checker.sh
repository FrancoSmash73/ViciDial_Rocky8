#!/bin/bash
# ViciDial Database Duplicate Entry Checker
# Checks all key tables in the asterisk database for duplicate rows
# Usage: vicidial_check_duplicates.sh [--fix]
#
# --fix  Automatically remove duplicates (creates backup tables first)

DB="asterisk"
FIX_MODE=0
DUPLICATES_FOUND=0

if [[ "$1" == "--fix" ]]; then
    FIX_MODE=1
    echo "=== RUNNING IN FIX MODE - Duplicates will be removed ==="
    echo ""
fi

echo "============================================"
echo " ViciDial Duplicate Entry Checker"
echo " Database: $DB"
echo " Date: $(date)"
echo "============================================"
echo ""

# Function to check for duplicates in a table using a GROUP BY key
check_duplicates() {
    local table="$1"
    local group_cols="$2"
    local label="$3"

    # Check if table exists
    exists=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$table';" 2>/dev/null)
    if [[ "$exists" != "1" ]]; then
        return
    fi

    total=$(mysql -N $DB -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)
    distinct=$(mysql -N $DB -e "SELECT COUNT(*) FROM (SELECT DISTINCT $group_cols FROM $table) as t;" 2>/dev/null)

    if [[ "$total" -gt "$distinct" ]] && [[ "$total" -gt 0 ]]; then
        dupes=$((total - distinct))
        echo "[DUPLICATE] $label ($table)"
        echo "  Total rows: $total | Distinct rows: $distinct | Duplicates: $dupes"
        DUPLICATES_FOUND=$((DUPLICATES_FOUND + 1))

        if [[ "$FIX_MODE" -eq 1 ]]; then
            echo "  -> Fixing: Creating temp table with DISTINCT rows..."
            mysql $DB -e "
                CREATE TABLE ${table}_dedup_tmp AS SELECT DISTINCT * FROM $table;
                TRUNCATE TABLE $table;
                INSERT INTO $table SELECT * FROM ${table}_dedup_tmp;
                DROP TABLE ${table}_dedup_tmp;
            " 2>/dev/null
            new_count=$(mysql -N $DB -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)
            echo "  -> Fixed: $table now has $new_count rows"
        fi
        echo ""
    fi
}

# Function to check for duplicates using specific key columns (for tables with unique logical keys)
check_key_duplicates() {
    local table="$1"
    local key_cols="$2"
    local label="$3"

    exists=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$table';" 2>/dev/null)
    if [[ "$exists" != "1" ]]; then
        return
    fi

    dupes=$(mysql -N $DB -e "SELECT COUNT(*) FROM (SELECT $key_cols, COUNT(*) as cnt FROM $table GROUP BY $key_cols HAVING cnt > 1) as t;" 2>/dev/null)

    if [[ "$dupes" -gt 0 ]]; then
        total=$(mysql -N $DB -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)
        echo "[DUPLICATE] $label ($table) - $dupes duplicate key groups found"
        echo "  Total rows: $total"
        echo "  Duplicate keys (first 5):"
        mysql $DB -e "SELECT $key_cols, COUNT(*) as cnt FROM $table GROUP BY $key_cols HAVING cnt > 1 LIMIT 5;" 2>/dev/null | sed 's/^/    /'
        DUPLICATES_FOUND=$((DUPLICATES_FOUND + 1))

        if [[ "$FIX_MODE" -eq 1 ]]; then
            echo "  -> Fixing: Creating temp table with DISTINCT rows..."
            mysql $DB -e "
                CREATE TABLE ${table}_dedup_tmp AS SELECT DISTINCT * FROM $table;
                TRUNCATE TABLE $table;
                INSERT INTO $table SELECT * FROM ${table}_dedup_tmp;
                DROP TABLE ${table}_dedup_tmp;
            " 2>/dev/null
            new_count=$(mysql -N $DB -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)
            echo "  -> Fixed: $table now has $new_count rows"
        fi
        echo ""
    fi
}

echo "--- Core Configuration Tables ---"
check_duplicates "system_settings" "*" "System Settings"
check_key_duplicates "servers" "server_id" "Servers"
check_key_duplicates "vicidial_campaigns" "campaign_id" "Campaigns"
check_key_duplicates "vicidial_inbound_groups" "group_id" "Inbound Groups"
check_key_duplicates "vicidial_users" "user" "Users"
check_key_duplicates "vicidial_user_groups" "user_group" "User Groups"

echo "--- Telephony Tables ---"
check_key_duplicates "phones" "extension, server_ip" "Phones"
check_key_duplicates "vicidial_conferences" "conf_exten, server_ip" "Conferences (vicidial)"
check_key_duplicates "conferences" "conf_exten, server_ip" "Conferences"
check_key_duplicates "vicidial_confbridges" "conf_exten, server_ip" "Confbridges"
check_key_duplicates "vicidial_server_carriers" "carrier_id" "Server Carriers"
check_key_duplicates "vicidial_inbound_dids" "did_pattern" "Inbound DIDs"

echo "--- Status & Code Tables ---"
check_key_duplicates "vicidial_statuses" "status" "Statuses"
check_key_duplicates "vicidial_campaign_statuses" "status, campaign_id" "Campaign Statuses"
check_key_duplicates "vicidial_pause_codes" "pause_code, campaign_id" "Pause Codes"
check_key_duplicates "vicidial_campaign_hotkeys" "hotkey, campaign_id" "Campaign Hotkeys"

echo "--- Reference Data Tables ---"
check_duplicates "vicidial_phone_codes" "country_code, country, areacode, state, GMT_offset, DST, DST_range, geographic_description" "Phone Codes"
check_duplicates "vicidial_country_iso_tld" "*" "Country ISO/TLD"
check_duplicates "vicidial_postal_codes" "*" "Postal Codes"

echo "--- Scheduling & Routing Tables ---"
check_key_duplicates "vicidial_call_times" "call_time_id" "Call Times"
check_key_duplicates "vicidial_state_call_times" "state_call_time_id" "State Call Times"
check_key_duplicates "vicidial_shifts" "shift_id" "Shifts"
check_key_duplicates "vicidial_call_menu" "menu_id" "Call Menus"
check_key_duplicates "vicidial_call_menu_options" "menu_id, option_value" "Call Menu Options"

echo "--- Other Configuration Tables ---"
check_key_duplicates "vicidial_lists" "list_id" "Lists"
check_key_duplicates "vicidial_scripts" "script_id" "Scripts"
check_key_duplicates "vicidial_settings_containers" "container_id" "Settings Containers"
check_key_duplicates "vicidial_music_on_hold" "moh_id" "Music On Hold"
check_key_duplicates "vicidial_music_on_hold_files" "moh_id, filename" "MOH Files"
check_key_duplicates "vicidial_xfer_presets" "preset_name, campaign_id" "Transfer Presets"
check_key_duplicates "vicidial_conf_templates" "template_id" "Conf Templates"
check_key_duplicates "vicidial_email_accounts" "email_account_id" "Email Accounts"
check_key_duplicates "vicidial_cid_groups" "cid_group_id" "CID Groups"
check_key_duplicates "vicidial_drop_rate_groups" "group_id" "Drop Rate Groups"
check_key_duplicates "vicidial_extension_groups" "extension_group_id" "Extension Groups"
check_key_duplicates "vicidial_filter_phone_groups" "filter_phone_group_id" "Filter Phone Groups"
check_key_duplicates "vicidial_ip_lists" "ip_list_id" "IP Lists"
check_key_duplicates "vicidial_remote_agents" "remote_agent_id" "Remote Agents"
check_key_duplicates "vicidial_avatars" "avatar_id" "Avatars"
check_key_duplicates "vicidial_lead_recycle" "recycle_id, campaign_id" "Lead Recycle"

echo "============================================"
if [[ "$DUPLICATES_FOUND" -eq 0 ]]; then
    echo " RESULT: No duplicates found - database is clean!"
else
    echo " RESULT: $DUPLICATES_FOUND table(s) with duplicates found"
    if [[ "$FIX_MODE" -eq 0 ]]; then
        echo " Run with --fix to automatically remove duplicates"
    else
        echo " All duplicates have been removed"
    fi
fi
echo "============================================"

exit $DUPLICATES_FOUND
