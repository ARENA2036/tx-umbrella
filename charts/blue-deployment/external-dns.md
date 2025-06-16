```bash
helm install externaldns bitnami/external-dns \
  --namespace kube-system \
  --set provider=azure \
  --set azure.resourceGroup=demo \
  --set azure.subscriptionId=88e4b2d4-aea1-4bd6-926d-120c90206d97 \
  --set azure.tenantId=83e5e9f7-dd5c-43e4-933d-fdc88385a4dd \
  --set azure.useManagedIdentityExtension=true \
  --set txtOwnerId=aks-externaldns \
  --set logLevel=info \
  --set policy=sync \
  --set domainFilters={arena2036-x.de} \
  --set sources=ingressgateway \
  --set registry=txt \
  --set txtPrefix=externaldns. \
  --set interval=1m
```