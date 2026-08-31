#!/usr/bin/env bash
# Разовая настройка публикации: проект Cloudflare Pages, секреты в GitHub и,
# по флагу --dns, переключение домена на новый сайт.
#
#   CLOUDFLARE_API_TOKEN=... ./scripts/setup-cloudflare.sh          # без DNS
#   CLOUDFLARE_API_TOKEN=... ./scripts/setup-cloudflare.sh --dns    # и DNS тоже
#
# Права токена: Account · Cloudflare Pages · Edit
#               Zone · DNS · Edit          (для musaev.me)
#               Zone · Zone · Read
set -euo pipefail

PROJECT="musaev-me"
DOMAIN="musaev.me"
REPO="zamirka/musaev.me"
API="https://api.cloudflare.com/client/v4"
DO_DNS=false
[[ "${1:-}" == "--dns" ]] && DO_DNS=true

: "${CLOUDFLARE_API_TOKEN:?Не задан CLOUDFLARE_API_TOKEN}"
H=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

jqr() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval('d$1'))" 2>/dev/null; }
ok()  { python3 -c "import json,sys;print('да' if json.load(sys.stdin).get('success') else 'нет')"; }

echo "== токен =="
# Проверяем не через /user/tokens/verify: account-owned токены (префикс cfat_)
# эту пользовательскую ручку не проходят, хотя сами полностью рабочие.
curl -sS -o /tmp/cf-check.json -w 'доступ к аккаунтам: HTTP %{http_code}\n' "${H[@]}" "$API/accounts"
python3 -c "
import json,sys
d=json.load(open('/tmp/cf-check.json'))
if not d.get('success'):
    print('Токен не принят:', d.get('errors')); sys.exit(1)
" || exit 1

echo "== аккаунт =="
ACCOUNTS=$(curl -sS "${H[@]}" "$API/accounts")
ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID:-$(echo "$ACCOUNTS" | python3 -c "
import json,sys
r=json.load(sys.stdin).get('result') or []
if len(r)!=1:
    print('', end=''); sys.exit(0)
print(r[0]['id'])")}
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "Аккаунтов не один – укажите CLOUDFLARE_ACCOUNT_ID. Доступные:"
  echo "$ACCOUNTS" | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('result') or []: print(' ', a['id'], a['name'])"
  exit 1
fi
echo "account id: $ACCOUNT_ID"

echo "== проект Pages =="
EXISTING=$(curl -sS "${H[@]}" "$API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT" | ok)
if [[ "$EXISTING" == "да" ]]; then
  echo "проект $PROJECT уже есть"
else
  curl -sS "${H[@]}" -X POST "$API/accounts/$ACCOUNT_ID/pages/projects" \
    -d "{\"name\":\"$PROJECT\",\"production_branch\":\"main\"}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('создан:', d['result']['subdomain']) if d.get('success') else print('ошибка:', d.get('errors'))"
fi

echo "== секреты в GitHub =="
gh secret set CLOUDFLARE_API_TOKEN  --repo "$REPO" --body "$CLOUDFLARE_API_TOKEN"
gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$REPO" --body "$ACCOUNT_ID"
gh secret list --repo "$REPO"

if ! $DO_DNS; then
  echo
  echo "DNS не трогал. Чтобы переключить домен, повторите с флагом --dns."
  exit 0
fi

echo "== DNS =="
ZONE_ID=$(curl -sS "${H[@]}" "$API/zones?name=$DOMAIN" | jqr "['result'][0]['id']")
echo "zone id: $ZONE_ID"

# Трогаем только адресные записи. На апексе живут MX и TXT (почта и SPF) –
# удалить их вместе с A-записью значит положить почту домена.
ADDR_TYPES="A AAAA CNAME"

echo "-- адресные записи апекса и www --"
curl -sS "${H[@]}" "$API/zones/$ZONE_ID/dns_records?per_page=200" | python3 -c "
import json,sys
for r in json.load(sys.stdin)['result']:
    if r['name'] in ('$DOMAIN','www.$DOMAIN') and r['type'] in '$ADDR_TYPES'.split():
        print(f\"  {r['type']:6} {r['name']:20} -> {r['content']:35} proxied={r['proxied']}\")"

read -r -p "Удалить эти записи и направить домен на $PROJECT.pages.dev? [y/N] " a
[[ "$a" == "y" || "$a" == "Y" ]] || { echo "Отменено."; exit 0; }

curl -sS "${H[@]}" "$API/zones/$ZONE_ID/dns_records?per_page=200" | python3 -c "
import json,sys
ids=[r['id'] for r in json.load(sys.stdin)['result']
     if r['name'] in ('$DOMAIN','www.$DOMAIN') and r['type'] in '$ADDR_TYPES'.split()]
print('\n'.join(ids))" | while read -r id; do
  [[ -n "$id" ]] && curl -sS "${H[@]}" -X DELETE "$API/zones/$ZONE_ID/dns_records/$id" >/dev/null && echo "  удалена $id"
done

for name in "$DOMAIN" "www.$DOMAIN"; do
  curl -sS "${H[@]}" -X POST "$API/zones/$ZONE_ID/dns_records" \
    -d "{\"type\":\"CNAME\",\"name\":\"$name\",\"content\":\"$PROJECT.pages.dev\",\"proxied\":true}" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  создана CNAME $name ->', d['result']['content']) if d.get('success') else print('  ошибка $name:', d.get('errors'))"
  curl -sS "${H[@]}" -X POST "$API/accounts/$ACCOUNT_ID/pages/projects/$PROJECT/domains" \
    -d "{\"name\":\"$name\"}" >/dev/null || true
done

echo
echo "Готово. Домены investing.musaev.me и vtwin.musaev.me не трогались."
