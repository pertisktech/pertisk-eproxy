# make docker-ingress-multi VERSION=0.1.28
make docker-ingress-multi VERSION=0.3.9
helm upgrade --install pertisk-eproxy ./deploy/helm/pertisk-eproxy -n pertisk-eproxy \
  --set image.tag=0.3.9\
  --set auth.username=admin \
  --set auth.password='admin' \
  --set auth0.domain=dev-od6cfzs2tugxm53g.us.auth0.com \
  --set auth0.clientId=djuW8aR7VZQeS9SbW4ddnRCitgc6TiKO \
  --set auth0.audience=https://dev-od6cfzs2tugxm53g.us.auth0.com/api/v2/ \
  --set adminIngress.enabled=true \
  --set adminIngress.host=admin.arm.thaidevops.co \
  --set adminIngress.tlsSecretName=admin-arm-tls