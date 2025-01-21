# Umbrella

![Version: 0.17.0](https://img.shields.io/badge/Version-0.17.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

A Helm chart to spin up Tractus-X OSS components to simulate a complete dataspace network.

With this Helm chart you are able to run end-to-end or create a sandbox environment.

This umbrella chart provides a basis for running end-to-end tests or creating a sandbox environment of the [Catena-X](https://catena-x.net/en/) automotive dataspace network consisting of [Tractus-X](https://projects.eclipse.org/projects/automotive.tractusx) OSS components.

The Chart aims for a completely automated setup of a fully functional network, that does not require manual setup steps.

## Azure Deployment
In order to install the umbrella helm chart, it is assumed that AKS cluster and ingress settings are already setup in Azure. It is good to install helm deployment via Azure CLI.For this, User authentication is required against the AKS CLI.

> ```bash
> helm install --debug umbrella -f values.yaml .
> ```


## Source Code

* <https://github.com/eclipse-tractusx/tractus-x-umbrella>

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| https://eclipse-tractusx.github.io/charts/dev | bpndiscovery | 0.2.6 |
| https://eclipse-tractusx.github.io/charts/dev | centralidp | 2.1.0 |
| https://eclipse-tractusx.github.io/charts/dev | discoveryfinder | 0.2.5 |
| https://eclipse-tractusx.github.io/charts/dev | managed-identity-wallet | 0.4.0 |
| https://eclipse-tractusx.github.io/charts/dev | portal | 1.8.1 |
| https://eclipse-tractusx.github.io/charts/dev | selfdescription(sdfactory) | 2.1.19 |
| https://eclipse-tractusx.github.io/charts/dev | semantic-hub | 0.2.3 |
| https://eclipse-tractusx.github.io/charts/dev | sharedidp | 2.1.0 |
| https://eclipse-tractusx.github.io/charts/dev | dataconsumerOne(tx-data-provider) | 0.0.5 |
| https://eclipse-tractusx.github.io/charts/dev | tx-data-provider | 0.0.5 |
| https://eclipse-tractusx.github.io/charts/dev | dataconsumerTwo(tx-data-provider) | 0.0.5 |
| https://helm.runix.net | pgadmin4 | 1.25.x |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| bpndiscovery.bpndiscovery.authentication | bool | `true` |  |
| bpndiscovery.bpndiscovery.bpndiscoverEndpoint.allowedTypes | string | `"oen,wmi,passtype,manufacturerPartId"` |  |
| bpndiscovery.bpndiscovery.bpndiscoverEndpoint.description | string | `"Service to discover BPN for different kind of type numbers"` |  |
| bpndiscovery.bpndiscovery.bpndiscoverEndpoint.documentation | string | `"/bpndiscovery/swagger-ui/index.html"` |  |
| bpndiscovery.bpndiscovery.bpndiscoverEndpoint.endpointAddress | string | `"/bpndiscovery"` |  |
| bpndiscovery.bpndiscovery.bpndiscoverEndpoint.timeToLive | string | `"31536000"` |  |
| bpndiscovery.bpndiscovery.host | string | `"semantics.tx.test"` |  |
| bpndiscovery.bpndiscovery.idp.issuerUri | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io.test/auth/realms/CX-Central"` |  |
| bpndiscovery.bpndiscovery.idp.publicClientId | string | `"Cl22-CX-BPND"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-credentials" | string | `"true"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."nginx.ingress.kubernetes.io/enable-cors" | string | `"true"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."nginx.ingress.kubernetes.io/rewrite-target" | string | `"/$2"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."nginx.ingress.kubernetes.io/use-regex" | string | `"true"` |  |
| bpndiscovery.bpndiscovery.ingress.annotations."nginx.ingress.kubernetes.io/x-forwarded-prefix" | string | `"/bpndiscovery"` |  |
| bpndiscovery.bpndiscovery.ingress.enabled | bool | `true` |  |
| bpndiscovery.bpndiscovery.ingress.ingressClassName | string | `""` |  |
| bpndiscovery.bpndiscovery.ingress.tls | bool | `false` |  |
| bpndiscovery.bpndiscovery.ingress.urlPrefix | string | `"/bpndiscovery"` |  |
| bpndiscovery.bpndiscovery.livenessProbe.initialDelaySeconds | int | `200` |  |
| bpndiscovery.bpndiscovery.readinessProbe.initialDelaySeconds | int | `200` |  |
| bpndiscovery.enablePostgres | bool | `true` |  |
| bpndiscovery.enabled | bool | `false` |  |
| bpndiscovery.postgresql.auth.password | string | `"dbpasswordbpndiscovery"` |  |
| bpndiscovery.postgresql.auth.postgresPassword | string | `"dbpasswordbpndiscovery"` |  |
| bpndiscovery.postgresql.nameOverride | string | `"bpndiscovery-postgresql"` |  |
| bpndiscovery.postgresql.primary.persistence.enabled | bool | `false` |  |
| bpndiscovery.postgresql.primary.persistence.size | string | `"8Gi"` |  |
| centralidp.enabled | bool | `true` |  |
| centralidp.keycloak.extraEnvVars[0].name | string | `"KEYCLOAK_EXTRA_ARGS"` |  |
| centralidp.keycloak.extraEnvVars[0].value | string | `"-Dkeycloak.migration.action=import -Dkeycloak.migration.provider=singleFile -Dkeycloak.migration.file=/realms/CX-Central-realm.json -Dkeycloak.migration.strategy=IGNORE_EXISTING"` |  |
| centralidp.keycloak.extraVolumeMounts[0].mountPath | string | `"/realms"` |  |
| centralidp.keycloak.extraVolumeMounts[0].name | string | `"realms"` |  |
| centralidp.keycloak.extraVolumeMounts[1].mountPath | string | `"/opt/bitnami/keycloak/themes/catenax-central"` |  |
| centralidp.keycloak.extraVolumeMounts[1].name | string | `"themes"` |  |
| centralidp.keycloak.extraVolumes[0].emptyDir | object | `{}` |  |
| centralidp.keycloak.extraVolumes[0].name | string | `"realms"` |  |
| centralidp.keycloak.extraVolumes[1].emptyDir | object | `{}` |  |
| centralidp.keycloak.extraVolumes[1].name | string | `"themes"` |  |
| centralidp.keycloak.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| centralidp.keycloak.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-credentials" | string | `"true"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-methods" | string | `"PUT, GET, POST, OPTIONS"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-origin" | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/enable-cors" | string | `"true"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffer-size" | string | `"128k"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffering" | string | `"on"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffers-number" | string | `"20"` |  |
| centralidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/use-regex" | string | `"true"` |  |
| centralidp.keycloak.ingress.enabled | bool | `true` |  |
| centralidp.keycloak.ingress.hostname | string | `"centralidp.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| centralidp.keycloak.ingress.ingressClassName | string | `""` |  |
| centralidp.keycloak.ingress.tls[0].hosts | list | `["centralidp.d37c3234d8454420babf.westeurope.aksapp.io"]` | Provide host for tls secret. |
| centralidp.keycloak.ingress.tls[0].secretName | string | `"centralidp.tx.test-tls"` |  |
| centralidp.keycloak.initContainers[0].args[0] | string | `"-c"` |  |
| centralidp.keycloak.initContainers[0].args[1] | string | `"echo \"Copying realms...\"\ncp -R /import/catenax-central/R2403/realms/* /realms\n"` |  |
| centralidp.keycloak.initContainers[0].command[0] | string | `"sh"` |  |
| centralidp.keycloak.initContainers[0].image | string | `"napcoredataspace.azurecr.io/portal-napcore-iam:latest"` |  |
| centralidp.keycloak.initContainers[0].imagePullPolicy | string | `"IfNotPresent"` |  |
| centralidp.keycloak.initContainers[0].name | string | `"realm-import"` |  |
| centralidp.keycloak.initContainers[0].volumeMounts[0].mountPath | string | `"/realms"` |  |
| centralidp.keycloak.initContainers[0].volumeMounts[0].name | string | `"realms"` |  |
| centralidp.keycloak.initContainers[1].args[0] | string | `"-c"` |  |
| centralidp.keycloak.initContainers[1].args[1] | string | `"echo \"Copying themes...\"\ncp -R /import/themes/catenax-central/* /themes\n"` |  |
| centralidp.keycloak.initContainers[1].command[0] | string | `"sh"` |  |
| centralidp.keycloak.initContainers[1].image | string | `"docker.io/tractusx/portal-iam:v2.1.0"` |  |
| centralidp.keycloak.initContainers[1].imagePullPolicy | string | `"IfNotPresent"` |  |
| centralidp.keycloak.initContainers[1].name | string | `"theme-import"` |  |
| centralidp.keycloak.initContainers[1].volumeMounts[0].mountPath | string | `"/themes"` |  |
| centralidp.keycloak.initContainers[1].volumeMounts[0].name | string | `"themes"` |  |
| centralidp.keycloak.nameOverride | string | `"centralidp"` |  |
| centralidp.keycloak.postgresql.architecture | string | `"standalone"` |  |
| centralidp.keycloak.postgresql.nameOverride | string | `"centralidp-postgresql"` |  |
| centralidp.keycloak.postgresql.primary.persistence.enabled | bool | `false` |  |
| centralidp.keycloak.proxy | string | `"edge"` |  |
| centralidp.keycloak.replicaCount | int | `1` |  |
| centralidp.secrets.auth.existingSecret.adminpassword | string | `"adminconsolepwcentralidp"` | Password for the admin username 'admin'. Secret-key 'admin-password'. |
| centralidp.secrets.postgresql.auth.existingSecret.password | string | `"dbpasswordcentralidp"` |  |
| centralidp.secrets.postgresql.auth.existingSecret.postgrespassword | string | `"dbpasswordcentralidp"` |  |
| centralidp.secrets.postgresql.auth.existingSecret.replicationPassword | string | `"dbpasswordcentralidp"` |  |
| dataconsumerOne.digital-twin-registry.enabled | bool | `false` |  |
| dataconsumerOne.enabled | bool | `true` |  |
| dataconsumerOne.nameOverride | string | `"dataconsumer-1"` |  |
| dataconsumerOne.secrets.edc-miw-keycloak-secret | string | `"UbfW4CR1xH4OskkovqJ2JzcwnQIrG7oj"` |  |
| dataconsumerOne.seedTestdata | bool | `false` |  |
| dataconsumerOne.simple-data-backend.enabled | bool | `false` |  |
| dataconsumerOne.tractusx-connector.controlplane.endpoints.management.authKey | string | `"TEST1"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].enabled | bool | `true` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].endpoints[0] | string | `"default"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].endpoints[1] | string | `"protocol"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].endpoints[2] | string | `"management"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].hostname | string | `"dataconsumer-1-controlplane.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].ingressClassName | string | `""` |  |
| dataconsumerOne.tractusx-connector.controlplane.ingresses[0].tls.enabled | bool | `true` |  |
| dataconsumerOne.tractusx-connector.controlplane.ssi.miw.authorityId | string | `"BPNL00000003CRHK"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ssi.miw.url | string | `"https://managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ssi.oauth.client.id | string | `"satest01"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ssi.oauth.client.secretAlias | string | `"edc-miw-keycloak-secret"` |  |
| dataconsumerOne.tractusx-connector.controlplane.ssi.oauth.tokenurl | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth/realms/CX-Central/protocol/openid-connect/token"` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].enabled | bool | `true` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].endpoints[0] | string | `"default"` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].endpoints[1] | string | `"public"` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].hostname | string | `"dataconsumer-1-dataplane.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].ingressClassName | string | `""` |  |
| dataconsumerOne.tractusx-connector.dataplane.ingresses[0].tls.enabled | bool | `true` |  |
| dataconsumerOne.tractusx-connector.nameOverride | string | `"dataconsumer-1-edc"` |  |
| dataconsumerOne.tractusx-connector.participant.id | string | `"BPNLCGI000000000"` |  |
| dataconsumerOne.tractusx-connector.postgresql.auth.password | string | `"dbpassworddataconsumerone"` |  |
| dataconsumerOne.tractusx-connector.postgresql.auth.postgresPassword | string | `"dbpassworddataconsumerone"` |  |
| dataconsumerOne.tractusx-connector.postgresql.jdbcUrl | string | `"jdbc:postgresql://{{ .Release.Name }}-dataconsumer-1-db:5432/edc"` |  |
| dataconsumerOne.tractusx-connector.postgresql.nameOverride | string | `"dataconsumer-1-db"` |  |
| dataconsumerOne.tractusx-connector.vault.hashicorp.url | string | `"http://edc-dataconsumer-1-vault:8200"` |  |
| dataconsumerOne.tractusx-connector.vault.secretNames.transferProxyTokenEncryptionAesKey | string | `"tokenEncryptionAesKey"` |  |
| dataconsumerOne.tractusx-connector.vault.secretNames.transferProxyTokenSignerPrivateKey | string | `"tokenSignerPrivateKey"` |  |
| dataconsumerOne.tractusx-connector.vault.secretNames.transferProxyTokenSignerPublicKey | string | `"tokenSignerPublicKey"` |  |
| dataconsumerOne.vault.enabled | bool | `true` |  |
| dataconsumerOne.vault.fullnameOverride | string | `"edc-dataconsumer-1-vault"` |  |
| dataconsumerOne.vault.nameOverride | string | `"edc-dataconsumer-1-vault"` |  |
| dataconsumerOne.vault.server.postStart | list | `[]` |  |
| dataconsumerTwo.digital-twin-registry.enabled | bool | `false` |  |
| dataconsumerTwo.enabled | bool | `false` |  |
| dataconsumerTwo.nameOverride | string | `"dataconsumer-2"` |  |
| dataconsumerTwo.secrets.edc-miw-keycloak-secret | string | `"tPwy4exxH1sXBRQouobSA2nNVaaPuwCs"` |  |
| dataconsumerTwo.seedTestdata | bool | `false` |  |
| dataconsumerTwo.simple-data-backend.enabled | bool | `false` |  |
| dataconsumerTwo.tractusx-connector.controlplane.endpoints.management.authKey | string | `"TEST3"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].enabled | bool | `true` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].endpoints[0] | string | `"default"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].endpoints[1] | string | `"protocol"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].endpoints[2] | string | `"management"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].hostname | string | `"dataconsumer-2-controlplane.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].ingressClassName | string | `""` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ingresses[0].tls.enabled | bool | `true` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ssi.miw.authorityId | string | `"BPNL00000003CRHK"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ssi.miw.url | string | `"https://managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ssi.oauth.client.id | string | `"satest03"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ssi.oauth.client.secretAlias | string | `"edc-miw-keycloak-secret"` |  |
| dataconsumerTwo.tractusx-connector.controlplane.ssi.oauth.tokenurl | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth/realms/CX-Central/protocol/openid-connect/token"` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].enabled | bool | `true` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].endpoints[0] | string | `"default"` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].endpoints[1] | string | `"public"` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].hostname | string | `"dataconsumer-2-dataplane.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].ingressClassName | string | `""` |  |
| dataconsumerTwo.tractusx-connector.dataplane.ingresses[0].tls.enabled | bool | `true` |  |
| dataconsumerTwo.tractusx-connector.nameOverride | string | `"dataconsumer-2-edc"` |  |
| dataconsumerTwo.tractusx-connector.participant.id | string | `"BPNL00000003AVTH"` |  |
| dataconsumerTwo.tractusx-connector.postgresql.auth.password | string | `"dbpassworddataconsumertwo"` |  |
| dataconsumerTwo.tractusx-connector.postgresql.auth.postgresPassword | string | `"dbpassworddataconsumertwo"` |  |
| dataconsumerTwo.tractusx-connector.postgresql.jdbcUrl | string | `"jdbc:postgresql://{{ .Release.Name }}-dataconsumer-2-db:5432/edc"` |  |
| dataconsumerTwo.tractusx-connector.postgresql.nameOverride | string | `"dataconsumer-2-db"` |  |
| dataconsumerTwo.tractusx-connector.vault.hashicorp.url | string | `"http://edc-dataconsumer-2-vault:8200"` |  |
| dataconsumerTwo.tractusx-connector.vault.secretNames.transferProxyTokenEncryptionAesKey | string | `"tokenEncryptionAesKey"` |  |
| dataconsumerTwo.tractusx-connector.vault.secretNames.transferProxyTokenSignerPrivateKey | string | `"tokenSignerPrivateKey"` |  |
| dataconsumerTwo.tractusx-connector.vault.secretNames.transferProxyTokenSignerPublicKey | string | `"tokenSignerPublicKey"` |  |
| dataconsumerTwo.vault.enabled | bool | `true` |  |
| dataconsumerTwo.vault.fullnameOverride | string | `"edc-dataconsumer-2-vault"` |  |
| dataconsumerTwo.vault.nameOverride | string | `"edc-dataconsumer-2-vault"` |  |
| dataconsumerTwo.vault.server.postStart | list | `[]` |  |
| discoveryfinder.discoveryfinder.authentication | bool | `true` |  |
| discoveryfinder.discoveryfinder.dataSource.url | string | `"jdbc:postgresql://{{ .Release.Name }}-discoveryfinder-postgresql:5432/discoveryfinder"` |  |
| discoveryfinder.discoveryfinder.host | string | `"semantics.tx.test"` |  |
| discoveryfinder.discoveryfinder.idp.issuerUri | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth/realms/CX-Central"` |  |
| discoveryfinder.discoveryfinder.idp.publicClientId | string | `"Cl21-CX-DF"` |  |
| discoveryfinder.discoveryfinder.ingress | object | `{"annotations":{"cert-manager.io/cluster-issuer":"letsencrypt-prod","kubernetes.io/ingress.class":"addon-http-application-routing","nginx.ingress.kubernetes.io/rewrite-target":"/$2","nginx.ingress.kubernetes.io/use-regex":"true","nginx.ingress.kubernetes.io/x-forwarded-prefix":"/discoveryfinder"},"enabled":true,"ingressClassName":"","tls":[{"hosts":["https://discoveryfinder.d37c3234d8454420babf.westeurope.aksapp.io/"],"secretName":"discoveryfinder.tx.test-tls"}],"urlPrefix":"/discoveryfinder"}` | docs: https://semantics.d37c3234d8454420babf.westeurope.aksapp.io/discoveryfinder/swagger-ui/index.html |
| discoveryfinder.discoveryfinder.ingress.tls[0].hosts | list | `["https://discoveryfinder.d37c3234d8454420babf.westeurope.aksapp.io/"]` | Provide host for tls secret. |
| discoveryfinder.discoveryfinder.livenessProbe.initialDelaySeconds | int | `200` |  |
| discoveryfinder.discoveryfinder.properties.discoveryfinder.initialEndpoints[0].description | string | `"Service to discover connector endpoints based on bpns"` |  |
| discoveryfinder.discoveryfinder.properties.discoveryfinder.initialEndpoints[0].documentation | string | `"https://discoveryfinder.d37c3234d8454420babf.westeurope.aksapp.io/api/administration/swagger/index.html"` |  |
| discoveryfinder.discoveryfinder.properties.discoveryfinder.initialEndpoints[0].endpointAddress | string | `"https://discoveryfinder.d37c3234d8454420babf.westeurope.aksapp.io/api/administration/Connectors/discovery"` |  |
| discoveryfinder.discoveryfinder.properties.discoveryfinder.initialEndpoints[0].type | string | `"bpn"` |  |
| discoveryfinder.discoveryfinder.readinessProbe.initialDelaySeconds | int | `200` |  |
| discoveryfinder.enablePostgres | bool | `true` |  |
| discoveryfinder.enabled | bool | `false` |  |
| discoveryfinder.postgresql.auth.password | string | `"dbpassworddiscoveryfinder"` |  |
| discoveryfinder.postgresql.auth.postgresPassword | string | `"dbpassworddiscoveryfinder"` |  |
| discoveryfinder.postgresql.nameOverride | string | `"discoveryfinder-postgresql"` |  |
| discoveryfinder.postgresql.primary.persistence.enabled | bool | `false` |  |
| discoveryfinder.postgresql.primary.persistence.size | string | `"8Gi"` |  |
| managed-identity-wallet.enabled | bool | `true` |  |
| managed-identity-wallet.ingress | object | `{"annotations":{"cert-manager.io/cluster-issuer":"letsencrypt-prod","kubernetes.io/ingress.class":"addon-http-application-routing","nginx.ingress.kubernetes.io/cors-allow-credentials":"true","nginx.ingress.kubernetes.io/cors-allow-methods":"GET","nginx.ingress.kubernetes.io/cors-allow-origin":"https://portal.d37c3234d8454420babf.westeurope.aksapp.io","nginx.ingress.kubernetes.io/enable-cors":"true"},"enabled":true,"hosts":[{"host":"managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io","paths":[{"path":"/","pathType":"ImplementationSpecific"}]}],"ingressClassName":"","tls":[{"hosts":["managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"],"secretName":"managed-identity-wallets.tx.test-tls"}]}` | docs: https://managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io/ui/swagger-ui/index.html |
| managed-identity-wallet.keycloak.enabled | bool | `false` |  |
| managed-identity-wallet.livenessProbe.initialDelaySeconds | int | `90` |  |
| managed-identity-wallet.miw.authorityWallet.bpn | string | `"BPNL00000003CRHK"` |  |
| managed-identity-wallet.miw.authorityWallet.name | string | `"Catena-X"` |  |
| managed-identity-wallet.miw.database.host | string | `"{{ .Release.Name }}-miw-postgres"` |  |
| managed-identity-wallet.miw.database.secret | string | `"{{ .Release.Name }}-miw-postgres"` |  |
| managed-identity-wallet.miw.host | string | `"managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| managed-identity-wallet.miw.keycloak.clientId | string | `"Cl5-CX-Custodian"` |  |
| managed-identity-wallet.miw.keycloak.realm | string | `"CX-Central"` |  |
| managed-identity-wallet.miw.keycloak.url | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth"` |  |
| managed-identity-wallet.miw.ssi.enforceHttpsInDidWebResolution | string | `"true"` |  |
| managed-identity-wallet.postgresql.auth.enablePostgresUser | bool | `true` |  |
| managed-identity-wallet.postgresql.auth.password | string | `"dbpasswordmiw"` |  |
| managed-identity-wallet.postgresql.auth.postgresPassword | string | `"dbpasswordmiw"` |  |
| managed-identity-wallet.postgresql.nameOverride | string | `"miw-postgres"` |  |
| managed-identity-wallet.postgresql.primary.persistence.enabled | bool | `false` |  |
| managed-identity-wallet.postgresql.primary.persistence.size | string | `"1Gi"` |  |
| managed-identity-wallet.readinessProbe.initialDelaySeconds | int | `90` |  |
| managed-identity-wallet.seeding.clientId | string | `"sa-cl5-custodian-2"` |  |
| managed-identity-wallet.seeding.clientSecret | string | `"UIqawwoohsvZ6AZOd1llLhnsUTKMWe4D"` |  |
| managed-identity-wallet.seeding.companies | object | `{"BPNL00000000BJTL":"BPN_SUB_TIER_C","BPNL00000003AVTH":"BPN_OEM_B","BPNL00000003AWSS":"BPN_IRS_TEST","BPNL00000003AXS3":"BPN_SUB_TIER_B","BPNL00000003AYRE":"BPN_OEM_A","BPNL00000003AZQP":"BPN_OEM_C","BPNL00000003B0Q0":"BPN_N_TIER_A","BPNL00000003B2OM":"BPN_TIER_A","BPNL00000003B3NX":"BPN_SUB_TIER_A","BPNL00000003B5MJ":"BPN_TIER_B","BPNL00000003B6LU":"BPN_DISMANTLER","BPNL00000003CML1":"BPN_TRACEX_A","BPNL00000003CNKC":"BPN_TRACEX_B","BPNL00000003CSGV":"BPN_TIER_C","BPNS0000000008ZZ":"BPN_TRACEX_A_SITE_A","BPNS00000008BDFH":"BPN_TRACEX_B_SITE_A"}` | Map of company BPN and company name. For each of these Companies, a MIW wallet will be created. |
| managed-identity-wallet.seeding.enabled | bool | `true` |  |
| pgadmin4.enabled | bool | `true` |  |
| pgadmin4.env.email | string | `"pgadmin4@txtest.org"` |  |
| pgadmin4.env.password | string | `"tractusxpgdamin4"` |  |
| pgadmin4.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| pgadmin4.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| pgadmin4.ingress.annotations."nginx.ingress.kubernetes.io/proxy-body-size" | string | `"8m"` |  |
| pgadmin4.ingress.annotations."nginx.ingress.kubernetes.io/use-regex" | string | `"true"` |  |
| pgadmin4.ingress.enabled | bool | `true` |  |
| pgadmin4.ingress.hosts[0].host | string | `"pgadmin4.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| pgadmin4.ingress.hosts[0].paths[0].path | string | `"/"` |  |
| pgadmin4.ingress.hosts[0].paths[0].pathType | string | `"Prefix"` |  |
| pgadmin4.ingress.ingressClassName | string | `""` |  |
| pgadmin4.ingress.tls[0].hosts | list | `["pgadmin4.d37c3234d8454420babf.westeurope.aksapp.io"]` | Provide host for tls secret. |
| pgadmin4.ingress.tls[0].secretName | string | `"pgadmin4.tx.test-tls"` |  |
| pgadmin4.persistentVolume.enabled | bool | `false` |  |
| portal.backend.administration.logging.bpdmLibrary | string | `"Debug"` |  |
| portal.backend.administration.logging.businessLogic | string | `"Debug"` |  |
| portal.backend.administration.logging.custodianLibrary | string | `"Debug"` |  |
| portal.backend.administration.logging.default | string | `"Debug"` |  |
| portal.backend.administration.logging.sdfactoryLibrary | string | `"Debug"` |  |
| portal.backend.administration.swaggerEnabled | bool | `true` |  |
| portal.backend.appmarketplace.logging.default | string | `"Debug"` |  |
| portal.backend.appmarketplace.logging.offersLibrary | string | `"Debug"` |  |
| portal.backend.appmarketplace.swaggerEnabled | bool | `true` |  |
| portal.backend.dotnetEnvironment | string | `"Development"` |  |
| portal.backend.ingress | object | `{"annotations":{"cert-manager.io/cluster-issuer":"letsencrypt-prod","kubernetes.io/ingress.class":"addon-http-application-routing","nginx.ingress.kubernetes.io/cors-allow-origin":"http://localhost:3000, https://*.d37c3234d8454420babf.westeurope.aksapp.io","nginx.ingress.kubernetes.io/enable-cors":"true","nginx.ingress.kubernetes.io/proxy-body-size":"8m","nginx.ingress.kubernetes.io/use-regex":"true"},"enabled":true,"hosts":[{"host":"portal-backend.d37c3234d8454420babf.westeurope.aksapp.io","paths":[{"backend":{"port":8080,"service":"registration-service"},"path":"/api/registration","pathType":"Prefix"},{"backend":{"port":8080,"service":"administration-service"},"path":"/api/administration","pathType":"Prefix"},{"backend":{"port":8080,"service":"notification-service"},"path":"/api/notification","pathType":"Prefix"},{"backend":{"port":8080,"service":"provisioning-service"},"path":"/api/provisioning","pathType":"Prefix"},{"backend":{"port":8080,"service":"marketplace-app-service"},"path":"/api/apps","pathType":"Prefix"},{"backend":{"port":8080,"service":"services-service"},"path":"/api/services","pathType":"Prefix"}]}],"ingressClassName":"","name":"portal-backend","tls":[{"hosts":["portal-backend.d37c3234d8454420babf.westeurope.aksapp.io"],"secretName":"portal-backend.tx.test-tls"}]}` | docs: https://portal-backend.37c3234d8454420babf.westeurope.aksapp.io/api/administration/swagger/index.html https://portal-backend.37c3234d8454420babf.westeurope.aksapp.io/api/registration/swagger/index.html https://portal-backend.37c3234d8454420babf.westeurope.aksapp.io/api/apps/swagger/index.html https://portal-backend.37c3234d8454420babf.westeurope.aksapp.io/api/services/swagger/index.html https://portal-backend.37c3234d8454420babf.westeurope.aksapp.io/api/notification/swagger/index.html |
| portal.backend.ingress.tls[0] | object | `{"hosts":["portal-backend.d37c3234d8454420babf.westeurope.aksapp.io"],"secretName":"portal-backend.tx.test-tls"}` | Provide tls secret. |
| portal.backend.ingress.tls[0].hosts | list | `["portal-backend.d37c3234d8454420babf.westeurope.aksapp.io"]` | Provide host for tls secret. |
| portal.backend.keycloak.central.clientId | string | `"sa-cl1-reg-2"` |  |
| portal.backend.keycloak.central.clientSecret | string | `"aEoUADDw2aNPa0WAaKGAyKfC80n8sKxJ"` |  |
| portal.backend.keycloak.central.jwtBearerOptions.requireHttpsMetadata | string | `"false"` |  |
| portal.backend.keycloak.shared.clientId | string | `"sa-cl1-reg-1"` |  |
| portal.backend.keycloak.shared.clientSecret | string | `"YPA1t6BMQtPtaG3fpH8Sa8Ac6KYbPUM7"` |  |
| portal.backend.mailing.host | string | `"smtp-server.default.svc.cluster.local"` |  |
| portal.backend.mailing.password | string | `"mysecretpassword"` |  |
| portal.backend.mailing.port | string | `"8025"` |  |
| portal.backend.mailing.senderEmail | string | `"info@napcoretx.com"` |  |
| portal.backend.mailing.user | string | `"myUser"` |  |
| portal.backend.notification.logging.default | string | `"Debug"` |  |
| portal.backend.notification.swaggerEnabled | bool | `true` |  |
| portal.backend.portalmigrations.logging.default | string | `"Debug"` |  |
| portal.backend.processesworker.bpdm.clientId | string | `"sa-cl7-cx-5"` |  |
| portal.backend.processesworker.bpdm.clientSecret | string | `"bWSck103qNJ0jZ1LVtG9mUAlcL7R5RLg"` |  |
| portal.backend.processesworker.custodian | object | `{"clientId":"sa-cl5-custodian-2","clientSecret":"UIqawwoohsvZ6AZOd1llLhnsUTKMWe4D"}` | no configuration for clearinghouse because it's an external component clientId and clientSecret aren't in the centralidp Keycloak clearinghouse:   clientId: "clearinghouse-client-id"   clientSecret: "" |
| portal.backend.processesworker.logging.bpdmLibrary | string | `"Debug"` |  |
| portal.backend.processesworker.logging.clearinghouseLibrary | string | `"Debug"` |  |
| portal.backend.processesworker.logging.custodianLibrary | string | `"Debug"` |  |
| portal.backend.processesworker.logging.default | string | `"Debug"` |  |
| portal.backend.processesworker.logging.offerProvider | string | `"Debug"` |  |
| portal.backend.processesworker.logging.processesLibrary | string | `"Debug"` |  |
| portal.backend.processesworker.logging.sdfactoryLibrary | string | `"Debug"` |  |
| portal.backend.processesworker.offerprovider.clientId | string | `"sa-cl2-03"` |  |
| portal.backend.processesworker.offerprovider.clientSecret | string | `"wyNYzSnyu4iGvj17XgLSl0aQxAPjTjmI"` |  |
| portal.backend.processesworker.sdfactory.clientId | string | `"sa-cl8-cx-1"` |  |
| portal.backend.processesworker.sdfactory.clientSecret | string | `"clbQOPHcVKY9tUUd068vyf8CrsPZ8BgZ"` |  |
| portal.backend.processesworker.sdfactory.issuerBpn | string | `"BPNL00000003CRHK"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.auth | string | `"false"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.from | string | `"info@napcoretx.com"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.host | string | `"smtp-server.default.svc.cluster.local"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.password | string | `"mysecretpassword"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.port | string | `"8025"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.replyTo | string | `"info@test.com"` |  |
| portal.backend.provisioning.sharedRealm.smtpServer.user | string | `"myUser"` |  |
| portal.backend.registration.logging.bpdmLibrary | string | `"Debug"` |  |
| portal.backend.registration.logging.default | string | `"Debug"` |  |
| portal.backend.registration.logging.registrationService | string | `"Debug"` |  |
| portal.backend.registration.swaggerEnabled | bool | `true` |  |
| portal.backend.services.logging.default | string | `"Debug"` |  |
| portal.backend.services.logging.offersLibrary | string | `"Debug"` |  |
| portal.backend.services.swaggerEnabled | bool | `true` |  |
| portal.bpdmPartnersPoolAddress | string | `"https://business-partners.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.bpdmPortalGateAddress | string | `"https://business-partners.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.centralidpAddress | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.clearinghouseAddress | string | `"https://validation.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.clearinghouseTokenAddress | string | `"https://keycloak.37c3234d8454420babf.westeurope.aksapp.io/realms/example/protocol/openid-connect/token"` |  |
| portal.custodianAddress | string | `"https://managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.enabled | bool | `true` |  |
| portal.frontend.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| portal.frontend.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| portal.frontend.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-origin" | string | `"https://*.37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.frontend.ingress.annotations."nginx.ingress.kubernetes.io/enable-cors" | string | `"true"` |  |
| portal.frontend.ingress.annotations."nginx.ingress.kubernetes.io/rewrite-target" | string | `"/$1"` |  |
| portal.frontend.ingress.annotations."nginx.ingress.kubernetes.io/use-regex" | string | `"true"` |  |
| portal.frontend.ingress.enabled | bool | `true` |  |
| portal.frontend.ingress.hosts[0].host | string | `"portal.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.frontend.ingress.hosts[0].paths[0].backend.port | int | `8080` |  |
| portal.frontend.ingress.hosts[0].paths[0].backend.service | string | `"portal"` |  |
| portal.frontend.ingress.hosts[0].paths[0].path | string | `"/(.*)"` |  |
| portal.frontend.ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| portal.frontend.ingress.hosts[0].paths[1].backend.port | int | `8080` |  |
| portal.frontend.ingress.hosts[0].paths[1].backend.service | string | `"registration"` |  |
| portal.frontend.ingress.hosts[0].paths[1].path | string | `"/registration/(.*)"` |  |
| portal.frontend.ingress.hosts[0].paths[1].pathType | string | `"ImplementationSpecific"` |  |
| portal.frontend.ingress.hosts[0].paths[2].backend.port | int | `8080` |  |
| portal.frontend.ingress.hosts[0].paths[2].backend.service | string | `"assets"` |  |
| portal.frontend.ingress.hosts[0].paths[2].path | string | `"/((assets|documentation)/.*)"` |  |
| portal.frontend.ingress.hosts[0].paths[2].pathType | string | `"ImplementationSpecific"` |  |
| portal.frontend.ingress.ingressClassName | string | `""` |  |
| portal.frontend.ingress.tls[0] | object | `{"hosts":["portal.d37c3234d8454420babf.westeurope.aksapp.io"],"secretName":"portal.tx.test-tls"}` | Provide tls secret. |
| portal.frontend.ingress.tls[0].hosts | list | `["portal.d37c3234d8454420babf.westeurope.aksapp.io"]` | Provide host for tls secret. |
| portal.portalAddress | string | `"https://portal.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.portalBackendAddress | string | `"https://portal-backend.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.postgresql.architecture | string | `"standalone"` |  |
| portal.postgresql.auth.password | string | `"dbpasswordportal"` |  |
| portal.postgresql.auth.portalPassword | string | `"dbpasswordportal"` |  |
| portal.postgresql.auth.provisioningPassword | string | `"dbpasswordportal"` |  |
| portal.postgresql.auth.replicationPassword | string | `"dbpasswordportal"` |  |
| portal.postgresql.nameOverride | string | `"portal-backend-postgresql"` |  |
| portal.postgresql.primary.persistence.enabled | bool | `false` |  |
| portal.replicaCount | int | `1` |  |
| portal.sdfactoryAddress | string | `"https://sdfactory.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.semanticsAddress | string | `"https://semantics.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| portal.sharedidpAddress | string | `"https://sharedidp.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| selfdescription.enabled | bool | `true` |  |
| selfdescription.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| selfdescription.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| selfdescription.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-credentials" | string | `"true"` |  |
| selfdescription.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-origin" | string | `"https://*.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| selfdescription.ingress.annotations."nginx.ingress.kubernetes.io/enable-cors" | string | `"true"` |  |
| selfdescription.ingress.enabled | bool | `true` |  |
| selfdescription.ingress.hosts[0].host | string | `"sdfactory.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| selfdescription.ingress.hosts[0].paths[0].path | string | `"/"` |  |
| selfdescription.ingress.hosts[0].paths[0].pathType | string | `"Prefix"` |  |
| selfdescription.ingress.ingressClassName | string | `""` |  |
| selfdescription.ingress.tls[0].hosts[0] | string | `"sdfactory.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| selfdescription.ingress.tls[0].tlsName | string | `"sdfactory.tx.test-tls"` |  |
| selfdescription.sdfactory.secret.authServerUrl | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth"` | Keycloak URL |
| selfdescription.sdfactory.secret.clearingHouseClientId | string | `"sa-cl2-01"` | Details for Clearing House Client ID |
| selfdescription.sdfactory.secret.clearingHouseClientSecret | string | `"w6Ib6d7hdltXwkdtsJYF3Cb6fEywia7S"` | Details for Clearing House Client Secret |
| selfdescription.sdfactory.secret.clearingHouseRealm | string | `"CX-Central"` | Details for Clearing House Realm |
| selfdescription.sdfactory.secret.clearingHouseServerUrl | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth/realms/CX-Central/protocol/openid-connect/token"` | Details for Clearing House URL |
| selfdescription.sdfactory.secret.clearingHouseUri | string | `""` | Details for Clearing House URI |
| selfdescription.sdfactory.secret.clientId | string | `"sa-cl5-custodian-1"` | Custodian wallet client id |
| selfdescription.sdfactory.secret.clientSecret | string | `"6pnnap7byS1TImL9Uj7g2psud9Fdq4tJ"` | Custodian wallet client secret |
| selfdescription.sdfactory.secret.custodianWalletUri | string | `"https://managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"` | Details for Custodian wallet URI |
| selfdescription.sdfactory.secret.jwkSetUri | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth/realms/CX-Central/protocol/openid-connect/certs"` | JWK Set URI |
| selfdescription.sdfactory.secret.realm | string | `"CX-Central"` | Keycloak Realm detail |
| selfdescription.sdfactory.secret.resource | string | `"Cl5-CX-Custodian"` | Keycloak Resource detail |
| semantic-hub.enableKeycloak | bool | `false` |  |
| semantic-hub.enabled | bool | `false` |  |
| semantic-hub.graphdb.enabled | bool | `true` |  |
| semantic-hub.graphdb.image | string | `"jena-fuseki-docker:4.7.0"` |  |
| semantic-hub.graphdb.imagePullPolicy | string | `"Never"` |  |
| semantic-hub.graphdb.storageClassName | string | `""` |  |
| semantic-hub.graphdb.storageSize | string | `"8Gi"` |  |
| semantic-hub.hub.authentication | bool | `false` |  |
| semantic-hub.hub.host | string | `"semantics.tx.test"` |  |
| semantic-hub.hub.ingress.annotations | list | `[]` |  |
| semantic-hub.hub.ingress.enabled | bool | `true` |  |
| semantic-hub.hub.ingress.ingressClassName | string | `""` |  |
| semantic-hub.hub.ingress.tls | bool | `false` |  |
| semantic-hub.hub.ingress.urlPrefix | string | `"/hub"` |  |
| semantic-hub.hub.livenessProbe.initialDelaySeconds | int | `200` |  |
| semantic-hub.hub.readinessProbe.initialDelaySeconds | int | `200` |  |
| semantic-hub.keycloak.postgresql.architecture | string | `"standalone"` |  |
| semantic-hub.keycloak.postgresql.primary.persistence.enabled | bool | `false` |  |
| sharedidp.enabled | bool | `true` |  |
| sharedidp.keycloak.extraEnvVars[0].name | string | `"KEYCLOAK_EXTRA_ARGS"` |  |
| sharedidp.keycloak.extraEnvVars[0].value | string | `"-Dkeycloak.migration.action=import -Dkeycloak.migration.provider=dir -Dkeycloak.migration.dir=/realms -Dkeycloak.migration.strategy=IGNORE_EXISTING"` |  |
| sharedidp.keycloak.extraVolumeMounts[0].mountPath | string | `"/realms"` |  |
| sharedidp.keycloak.extraVolumeMounts[0].name | string | `"realms"` |  |
| sharedidp.keycloak.extraVolumeMounts[1].mountPath | string | `"/opt/bitnami/keycloak/themes/catenax-shared"` |  |
| sharedidp.keycloak.extraVolumeMounts[1].name | string | `"themes-catenax-shared"` |  |
| sharedidp.keycloak.extraVolumeMounts[2].mountPath | string | `"/opt/bitnami/keycloak/themes/catenax-shared-portal"` |  |
| sharedidp.keycloak.extraVolumeMounts[2].name | string | `"themes-catenax-shared-portal"` |  |
| sharedidp.keycloak.extraVolumes[0].emptyDir | object | `{}` |  |
| sharedidp.keycloak.extraVolumes[0].name | string | `"realms"` |  |
| sharedidp.keycloak.extraVolumes[1].emptyDir | object | `{}` |  |
| sharedidp.keycloak.extraVolumes[1].name | string | `"themes-catenax-shared"` |  |
| sharedidp.keycloak.extraVolumes[2].emptyDir | object | `{}` |  |
| sharedidp.keycloak.extraVolumes[2].name | string | `"themes-catenax-shared-portal"` |  |
| sharedidp.keycloak.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| sharedidp.keycloak.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-credentials" | string | `"true"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-methods" | string | `"PUT, GET, POST, OPTIONS"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/cors-allow-origin" | string | `"https://sharedidp.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/enable-cors" | string | `"true"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffer-size" | string | `"128k"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffering" | string | `"on"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/proxy-buffers-number" | string | `"20"` |  |
| sharedidp.keycloak.ingress.annotations."nginx.ingress.kubernetes.io/use-regex" | string | `"true"` |  |
| sharedidp.keycloak.ingress.enabled | bool | `true` |  |
| sharedidp.keycloak.ingress.hostname | string | `"sharedidp.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| sharedidp.keycloak.ingress.ingressClassName | string | `""` |  |
| sharedidp.keycloak.ingress.tls[0].hosts | list | `["sharedidp.d37c3234d8454420babf.westeurope.aksapp.io"]` | Provide host for tls secret. |
| sharedidp.keycloak.ingress.tls[0].secretName | string | `"sharedidp.tx.test-tls"` |  |
| sharedidp.keycloak.initContainers[0].args[0] | string | `"-c"` |  |
| sharedidp.keycloak.initContainers[0].args[1] | string | `"echo \"Copying realms...\"\ncp -R /import/catenax-shared/realms/* /realms\n"` |  |
| sharedidp.keycloak.initContainers[0].command[0] | string | `"sh"` |  |
| sharedidp.keycloak.initContainers[0].image | string | `"napcoredataspace.azurecr.io/portal-napcore-iam:latest"` |  |
| sharedidp.keycloak.initContainers[0].imagePullPolicy | string | `"IfNotPresent"` |  |
| sharedidp.keycloak.initContainers[0].name | string | `"realm-import"` |  |
| sharedidp.keycloak.initContainers[0].volumeMounts[0].mountPath | string | `"/realms"` |  |
| sharedidp.keycloak.initContainers[0].volumeMounts[0].name | string | `"realms"` |  |
| sharedidp.keycloak.initContainers[1].args[0] | string | `"-c"` |  |
| sharedidp.keycloak.initContainers[1].args[1] | string | `"echo \"Copying themes-catenax-shared...\"\ncp -R /import/themes/catenax-shared/* /themes-catenax-shared\necho \"Copying themes-catenax-shared-portal...\"\ncp -R /import/themes/catenax-shared-portal/* /themes-catenax-shared-portal\n"` |  |
| sharedidp.keycloak.initContainers[1].command[0] | string | `"sh"` |  |
| sharedidp.keycloak.initContainers[1].image | string | `"docker.io/tractusx/portal-iam:v2.1.0"` |  |
| sharedidp.keycloak.initContainers[1].imagePullPolicy | string | `"IfNotPresent"` |  |
| sharedidp.keycloak.initContainers[1].name | string | `"theme-import"` |  |
| sharedidp.keycloak.initContainers[1].volumeMounts[0].mountPath | string | `"/themes-catenax-shared"` |  |
| sharedidp.keycloak.initContainers[1].volumeMounts[0].name | string | `"themes-catenax-shared"` |  |
| sharedidp.keycloak.initContainers[1].volumeMounts[1].mountPath | string | `"/themes-catenax-shared-portal"` |  |
| sharedidp.keycloak.initContainers[1].volumeMounts[1].name | string | `"themes-catenax-shared-portal"` |  |
| sharedidp.keycloak.nameOverride | string | `"sharedidp"` |  |
| sharedidp.keycloak.postgresql.architecture | string | `"standalone"` |  |
| sharedidp.keycloak.postgresql.nameOverride | string | `"sharedidp-postgresql"` |  |
| sharedidp.keycloak.postgresql.primary.persistence.enabled | bool | `false` |  |
| sharedidp.keycloak.proxy | string | `"edge"` |  |
| sharedidp.keycloak.replicaCount | int | `1` |  |
| sharedidp.secrets.auth.existingSecret.adminpassword | string | `"adminconsolepwsharedidp"` | Password for the admin username 'admin'. Secret-key 'admin-password'. |
| sharedidp.secrets.postgresql.auth.existingSecret.password | string | `"dbpasswordsharedidp"` |  |
| sharedidp.secrets.postgresql.auth.existingSecret.postgrespassword | string | `"dbpasswordsharedidp"` |  |
| sharedidp.secrets.postgresql.auth.existingSecret.replicationPassword | string | `"dbpasswordsharedidp"` |  |
| tx-data-provider.backendUrl | string | `"http://{{ .Release.Name }}-dataprovider-submodelserver:8080"` |  |
| tx-data-provider.controlplaneManagementUrl | string | `"http://{{ .Release.Name }}-dataprovider-edc-controlplane:8081"` |  |
| tx-data-provider.controlplanePublicUrl | string | `"http://{{ .Release.Name }}-dataprovider-edc-controlplane:8084"` |  |
| tx-data-provider.dataplaneUrl | string | `"http://{{ .Release.Name }}-dataprovider-edc-dataplane:8081"` |  |
| tx-data-provider.digital-twin-registry.nameOverride | string | `"dataprovider-dtr"` |  |
| tx-data-provider.digital-twin-registry.postgresql.auth.existingSecret | string | `"dataprovider-secret-dtr-postgres-init"` |  |
| tx-data-provider.digital-twin-registry.postgresql.auth.password | string | `"dbpassworddtrdataprovider"` |  |
| tx-data-provider.digital-twin-registry.postgresql.nameOverride | string | `"dataprovider-dtr-db"` |  |
| tx-data-provider.digital-twin-registry.registry.host | string | `"dataprovider-dtr.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| tx-data-provider.enabled | bool | `true` |  |
| tx-data-provider.nameOverride | string | `"dataprovider"` |  |
| tx-data-provider.registryUrl | string | `"http://{{ .Release.Name }}-dataprovider-dtr:8080/api/v3.0"` |  |
| tx-data-provider.secrets.edc-miw-keycloak-secret | string | `"pyFUZP2L9UCSVJUScHcN3ZEgy2PGyEpg"` |  |
| tx-data-provider.seedTestdata | bool | `true` |  |
| tx-data-provider.simple-data-backend.image.repository | string | `"napcoredataspace.azurecr.io/simple-data-backend"` |  |
| tx-data-provider.simple-data-backend.image.tag | string | `"v4.0"` |  |
| tx-data-provider.simple-data-backend.ingress.annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| tx-data-provider.simple-data-backend.ingress.annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| tx-data-provider.simple-data-backend.ingress.annotations."nginx.ingress.kubernetes.io/proxy-body-size" | string | `"50m"` |  |
| tx-data-provider.simple-data-backend.ingress.enabled | bool | `true` |  |
| tx-data-provider.simple-data-backend.ingress.hosts[0].host | string | `"data-service.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| tx-data-provider.simple-data-backend.ingress.hosts[0].paths[0].path | string | `"/"` |  |
| tx-data-provider.simple-data-backend.ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| tx-data-provider.simple-data-backend.ingress.ingressClassName | string | `""` |  |
| tx-data-provider.simple-data-backend.ingress.tls[0].hosts[0] | string | `"data-service.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| tx-data-provider.simple-data-backend.ingress.tls[0].secretName | string | `"data-service.tx.test-tls"` |  |
| tx-data-provider.simple-data-backend.nameOverride | string | `"dataprovider-submodelserver"` |  |
| tx-data-provider.simple-data-backend.resources.limits.cpu | string | `"500m"` |  |
| tx-data-provider.simple-data-backend.resources.limits.memory | string | `"1024Mi"` |  |
| tx-data-provider.simple-data-backend.resources.requests.cpu | string | `"500m"` |  |
| tx-data-provider.simple-data-backend.resources.requests.memory | string | `"1024Mi"` |  |
| tx-data-provider.tractusx-connector.controlplane.endpoints.management.authKey | string | `"TEST2"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].enabled | bool | `true` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].endpoints[0] | string | `"default"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].endpoints[1] | string | `"protocol"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].endpoints[2] | string | `"management"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].hostname | string | `"dataprovider-controlplane.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].ingressClassName | string | `""` |  |
| tx-data-provider.tractusx-connector.controlplane.ingresses[0].tls.enabled | bool | `true` |  |
| tx-data-provider.tractusx-connector.controlplane.ssi.miw.authorityId | string | `"BPNL00000003CRHK"` |  |
| tx-data-provider.tractusx-connector.controlplane.ssi.miw.url | string | `"https://managed-identity-wallets.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| tx-data-provider.tractusx-connector.controlplane.ssi.oauth.client.id | string | `"satest02"` |  |
| tx-data-provider.tractusx-connector.controlplane.ssi.oauth.client.secretAlias | string | `"edc-miw-keycloak-secret"` |  |
| tx-data-provider.tractusx-connector.controlplane.ssi.oauth.tokenurl | string | `"https://centralidp.d37c3234d8454420babf.westeurope.aksapp.io/auth/realms/CX-Central/protocol/openid-connect/token"` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].annotations."cert-manager.io/cluster-issuer" | string | `"letsencrypt-prod"` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].annotations."kubernetes.io/ingress.class" | string | `"addon-http-application-routing"` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].enabled | bool | `true` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].endpoints[0] | string | `"default"` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].endpoints[1] | string | `"public"` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].hostname | string | `"dataprovider-dataplane.d37c3234d8454420babf.westeurope.aksapp.io"` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].ingressClassName | string | `""` |  |
| tx-data-provider.tractusx-connector.dataplane.ingresses[0].tls.enabled | bool | `true` |  |
| tx-data-provider.tractusx-connector.nameOverride | string | `"dataprovider-edc"` |  |
| tx-data-provider.tractusx-connector.participant.id | string | `"BPNL000000000NDW"` |  |
| tx-data-provider.tractusx-connector.postgresql.auth.password | string | `"dbpasswordtxdataprovider"` |  |
| tx-data-provider.tractusx-connector.postgresql.auth.postgresPassword | string | `"dbpasswordtxdataprovider"` |  |
| tx-data-provider.tractusx-connector.postgresql.jdbcUrl | string | `"jdbc:postgresql://{{ .Release.Name }}-dataprovider-db:5432/edc"` |  |
| tx-data-provider.tractusx-connector.postgresql.nameOverride | string | `"dataprovider-db"` |  |
| tx-data-provider.tractusx-connector.vault.hashicorp.url | string | `"http://edc-dataprovider-vault:8200"` |  |
| tx-data-provider.tractusx-connector.vault.secretNames.transferProxyTokenEncryptionAesKey | string | `"tokenEncryptionAesKey"` |  |
| tx-data-provider.tractusx-connector.vault.secretNames.transferProxyTokenSignerPrivateKey | string | `"tokenSignerPrivateKey"` |  |
| tx-data-provider.tractusx-connector.vault.secretNames.transferProxyTokenSignerPublicKey | string | `"tokenSignerPublicKey"` |  |
| tx-data-provider.vault.enabled | bool | `true` |  |
| tx-data-provider.vault.fullnameOverride | string | `"edc-dataprovider-vault"` |  |
| tx-data-provider.vault.nameOverride | string | `"edc-dataprovider-vault"` |  |
| tx-data-provider.vault.server.postStart | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.11.0](https://github.com/norwoodj/helm-docs/releases/v1.11.0)
