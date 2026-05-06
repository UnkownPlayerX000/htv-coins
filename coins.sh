#!/usr/bin/env bash

set -euo pipefail

# Colors for better logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

getSHA256() {
    echo -n "$1" | sha256sum | cut -d' ' -f1
}

XClaim=$(date +%s)
host="https://hanime.tv"
session_file="htv.session"
XSig=$(getSHA256 "9944822${XClaim}8${XClaim}113")

hanime_email=${HTV_EMAIL:-"${1:-}"}
hanime_password=${HTV_PASSWORD:-"${2:-}"}

if [[ -z "$hanime_email" ]] || [[ -z "$hanime_password" ]]; then
    printf "${RED}[!] Please provide your hanime email and password as arguments or set env vars for 'HTV_EMAIL' and 'HTV_PASSWORD'.${NC}\n"
    exit 1
fi

# Common curl flags for reliability
CURL_FLAGS=(-s -S --retry 3 --connect-timeout 10 --max-time 30)

login() {
    local email="$1"
    local password="$2"
    local headers=(-H "Content-Type: application/json" -H "X-Signature-Version: app2" -H "X-Claim: ${XClaim}" -H "X-Signature: ${XSig}")
    
    local response=$(curl "${CURL_FLAGS[@]}" -X POST "${host}/rapi/v4/sessions" "${headers[@]}" -d "{\"burger\":\"${email}\",\"fries\":\"${password}\"}")
    
    local session_token=$(echo "$response" | jq -r .session_token)
    if [[ "$session_token" == "null" ]]; then
        printf "${RED}[!] Login failed. Please check your credentials.${NC}\n"
        echo "$response"
        exit 1
    fi

    echo "$session_token" | openssl enc -e -des3 -base64 -pass pass:"$password" -pbkdf2 > "$session_file"
    echo "$response"
}

get_info() {
    local session_token="$1"
    local headers=(-H "Content-Type: application/json" -H "X-Signature-Version: app2" -H "X-Claim: ${XClaim}" -H "X-Signature: ${XSig}" -H "X-Session-Token:${session_token}")
    curl "${CURL_FLAGS[@]}" -X GET "${host}/rapi/v4/home" "${headers[@]}"
}

get_coins() {
    local session_token="$1"
    local version="$2"
    local uid="$3"
    local curr_time=$(date +%s)
    local to_hash="coins${version}|${uid}|${curr_time}|coins${version}"
    local reward_token=$(getSHA256 "${to_hash}")
    local headers=(-H "Content-Type: application/json" -H "X-Signature-Version: app2" -H "X-Claim: ${XClaim}" -H "X-Signature: ${XSig}" -H "X-Session-Token: ${session_token}")
    
    local response=$(curl "${CURL_FLAGS[@]}" -X POST "${host}/rapi/v4/coins" "${headers[@]}" -d "{\"reward_token\":\"${reward_token}|${curr_time}\",\"version\":\"${version}\"}")
    
    if [[ "${response}" == *"Unauthorized"* ]]; then
        printf "${YELLOW}[!] Something went wrong. Most probably you have already collected your coins.${NC}\n"
        exit 0 # Exit gracefully if already collected
    fi
    
    local amount=$(echo "${response}" | jq -r '.rewarded_amount // 0')
    printf "${GREEN}[+] Success! You received ${amount} coins.${NC}\n"
}

main() {
    local info=""
    local session_token=""

    if [[ -s "$session_file" ]]; then
        printf "${BLUE}[#] Session file found. Decrypting...${NC}\n"
        session_token=$(openssl enc -d -des3 -base64 -pass pass:"$hanime_password" -pbkdf2 -in "$session_file" 2>/dev/null || echo "bad")
        
        if [[ "$session_token" == "bad" ]]; then
            printf "${YELLOW}[!] Incorrect password or corrupted session file. Falling back to login...${NC}\n"
            rm -f "$session_file"
        else
            info=$(get_info "${session_token}")
            if [[ "${info}" == *"Unauthorized"* ]]; then
                printf "${YELLOW}[#] Session expired. Refreshing...${NC}\n"
                info=$(login "${hanime_email}" "${hanime_password}")
                session_token=$(echo "$info" | jq -r .session_token)
            fi
        fi
    fi

    if [[ -z "$session_token" ]] || [[ "$session_token" == "bad" ]]; then
        printf "${BLUE}[#] Requesting new session...${NC}\n"
        info=$(login "${hanime_email}" "${hanime_password}")
        session_token=$(echo "${info}" | jq -r .session_token)
    fi

    local uid=$(echo "${info}" | jq -r .user.id)
    local name=$(echo "${info}" | jq -r .user.name)
    local coins=$(echo "${info}" | jq -r .user.coins)
    local last_click_date=$(echo "${info}" | jq -r .user.last_rewarded_ad_clicked_at)
    local version=$(echo "${info}" | jq -r .env.mobile_apps._build_number)

    printf "${GREEN}[*] Logged in as: ${name} (${uid})${NC}\n"
    printf "[*] Coins count: ${coins}\n"
    printf "[*] Last claim:  ${last_click_date:-Never}\n"
    printf "[*] App Version: ${version}\n"

    local current_time=$(date '+%s')
    if [[ -n "$last_click_date" ]] && [[ "$last_click_date" != "null" ]]; then
        local predicted_time=$(date -d "${last_click_date} + 3 hours" +"%s" 2>/dev/null || date -d "${last_click_date} 3 hours" +"%s")
        if [[ "$current_time" -gt "$predicted_time" ]]; then
            get_coins "$session_token" "$version" "$uid"
        else
            local next_time_readable=$(date -d @"$predicted_time" '+%F %T')
            printf "${YELLOW}[!] Next collection available at: ${next_time_readable}${NC}\n"
        fi
    else
        printf "${BLUE}[#] First time claiming coins!${NC}\n"
        get_coins "$session_token" "$version" "$uid"
    fi
}

main