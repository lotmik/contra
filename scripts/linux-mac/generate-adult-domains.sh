#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${ROOT_DIR}/data/adult-domains.txt"

BON_APPETIT_URL="https://raw.githubusercontent.com/Bon-Appetit/porn-domains/6113a623850e42df1643c1b6a322b61008f92f19/block.bf3755e532.hot0qe.txt"
ANTI_PORN_HOSTS_URL="https://raw.githubusercontent.com/4skinSkywalker/Anti-Porn-HOSTS-File/921fd38223f7e0a06d6d31fc233101a9f663b3cb/HOSTS.txt"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "Downloading source lists..."
curl -sS --max-time 240 -L "${BON_APPETIT_URL}" -o "${tmp_dir}/bon-appetit.txt"
curl -sS --max-time 240 -L "${ANTI_PORN_HOSTS_URL}" -o "${tmp_dir}/anti-porn-hosts.txt"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

echo "Normalizing and deduplicating..."
{
  awk 'NF { print tolower($1) }' "${tmp_dir}/bon-appetit.txt"
  awk 'NF >= 2 { print tolower($2) }' "${tmp_dir}/anti-porn-hosts.txt"
} \
  | sed 's/[[:space:]]//g' \
  | sed 's/^\.+//; s/\.+$//' \
  | rg -v '(^$|[^a-z0-9.-])' \
  | awk 'length($0) <= 253 && index($0, ".") > 0' \
  | LC_ALL=C sort -u \
  > "${OUTPUT_FILE}"

echo "Done."
wc -l "${OUTPUT_FILE}"
wc -c "${OUTPUT_FILE}"
