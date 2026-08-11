# Follow-up to CS IT — HAProxy not forwarding ml-capstone.cs.byu.edu

Hi again,

Thanks for the cert — it installed cleanly on our side and Traefik on rigel is serving `ml-capstone.cs.byu.edu` correctly (verified locally). But HAProxy at `haproxy1.cs.byu.edu` (128.187.80.8) doesn't seem to be forwarding the SNI to us yet — GitHub webhook deliveries are failing with EOF, and I can reproduce the failure from both my Mac and from rigel itself.

## Symptoms

**From GitHub's webhook delivery log:**
> POST https://ml-capstone.cs.byu.edu/webhooks/source/github/events
> giving up after 1 attempt(s): EOF

**Reproducer from any client (Mac on VPN, rigel on campus — both fail):**
```
$ openssl s_client -connect 128.187.80.8:443 -servername ml-capstone.cs.byu.edu </dev/null
Connecting to 128.187.80.8
error:0A000126:SSL routines::unexpected eof while reading
CONNECTED(00000003)
---
no peer certificate available
---
SSL handshake has read 0 bytes and written 1560 bytes
```

Reads `0 bytes and written 1560 bytes` — HAProxy accepts the TCP connection, receives the ClientHello (with SNI = `ml-capstone.cs.byu.edu`), then closes without doing anything else.

## Our side is confirmed healthy

From rigel itself, hitting Traefik directly with the same SNI works fine:
```
$ curl --resolve ml-capstone.cs.byu.edu:443:127.0.0.1 -sS -X POST \
    -o /dev/null -w '%{http_code}\n' \
    https://ml-capstone.cs.byu.edu/webhooks/source/github/events
200
```

So Traefik is happy to terminate TLS with the wildcard cert and route `/webhooks/*` to Coolify — we just need HAProxy to forward the SNI-matched traffic to it.

## What we think is missing

HAProxy needs a `use_backend` rule tied to `req_ssl_sni -i ml-capstone.cs.byu.edu` that targets `rigel.cs.byu.edu:443`. Something along the lines of:

```
frontend https-in
    bind :443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend rigel-mlcapstone if { req_ssl_sni -i ml-capstone.cs.byu.edu }

backend rigel-mlcapstone
    mode tcp
    server rigel rigel.cs.byu.edu:443
```

(Adjust names/frontend to fit your config — the shape is what matters.)

If instead you've configured an IP allowlist that's rejecting non-listed sources, that could produce the same symptom. Happy to hear GitHub's hooks IP list is now in place; we'd just want to know so we can test with confidence.

Thanks!
— Quinn
