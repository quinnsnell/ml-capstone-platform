# Reply to CS IT — SSL passthrough plan

Thanks for the clarification — SSL passthrough with rigel terminating TLS on our side works well for us. A few follow-ups:

## 1. Cert

When convenient, please send the cert + key for `ml-capstone.cs.byu.edu`. We'll install it into our Traefik (Coolify's built-in reverse proxy on rigel:443) and set up the `/webhooks/*` route.

**Optional bonus:** if it's easy to issue a wildcard `*.ml-capstone.cs.byu.edu` while you're at it, that would let us also terminate TLS on student app hostnames as they come online. Not blocking though — a single-host cert for the webhook domain is enough to get us going.

## 2. GitHub IP restriction

Yes, please — that would be great. GitHub publishes their current webhook source IPs at `https://api.github.com/meta` under the `hooks` key (currently ~30 CIDR blocks; they update occasionally). If maintaining that list is a hassle, no worries — we'd rather get the basic proxy up first and add the restriction later.

## 3. DNS records still on the table?

Just confirming the two internal-DNS A records I asked for are still workable:

- `testQ.ml-capstone.cs.byu.edu` → rigel IP
- `testM.ml-capstone.cs.byu.edu` → rigel IP

These are for VPN-only student test apps and don't need TLS or the reverse proxy — just internal DNS resolution. More records will come as the class ramps up.

Thanks again — happy to hop on a call if any of it needs walking through.

— Quinn
