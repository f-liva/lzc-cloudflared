#!/bin/sh
# Self-check for the lzc-cloudflared config API. Run: sh test-api.sh [base-url]
# Builds nothing: point it at a running container.
B="${1:-http://127.0.0.1:38500}/cgi-bin/api"
TOK=eyJhIjoiMzM1ZTYzOWI2Nzk3NzQ2NTM4MDBkNTgxMTVkNjFlNmMiLCJ0IjoiNGI0ZmIxMzUifQ
fail=0
t() { # t <label> <expected-substring> <curl args...>
  l=$1; e=$2; shift 2
  o=$(curl -s -m8 "$@")
  case "$o" in *"$e"*) echo "ok   $l";; *) echo "FAIL $l: want '$e', got '$o'"; fail=1;; esac
}
t "status is valid json"      '"running"'                  "$B?a=status"
t "save needs POST"           'serve POST'                 "$B?a=save"
t "rejects bad protocol"      'protocollo non valido'      -X POST "$B?a=save" -d "protocol=telnet&ha_connections=1&dns_fallback=&token=$TOK"
t "rejects ha out of range"   'da 1 a 4'                   -X POST "$B?a=save" -d "protocol=quic&ha_connections=9&dns_fallback=&token=$TOK"
t "rejects shell in resolver" 'resolver non valido'        -X POST "$B?a=save" -d "protocol=quic&ha_connections=1&dns_fallback=1.1.1.1%20evil%3Bls&token=$TOK"
t "rejects malformed token"   'formato valido'             -X POST "$B?a=save" -d 'protocol=quic&ha_connections=1&dns_fallback=&token=short'
t "unknown action"            'azione sconosciuta'         "$B?a=nope"
t "accepts valid settings"    '"ok":true'                  -X POST "$B?a=save" -d "protocol=http2&ha_connections=3&dns_fallback=9.9.9.9&token=$TOK"
t "settings round-trip"       '"ha_connections":"3"'       "$B?a=status"
t "empty token keeps stored"  '"ok":true'                  -X POST "$B?a=save" -d 'protocol=quic&ha_connections=1&dns_fallback=1.1.1.1'
t "token still present"       '"has_token":true'           "$B?a=status"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
