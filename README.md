## How to start

```bash
docker-compose up -d
docker-compose exec ingress ash
# install requirements
apk add perl curl && opm get ledgetech/lua-resty-http bungle/lua-resty-template

# start nginx
nginx
```
