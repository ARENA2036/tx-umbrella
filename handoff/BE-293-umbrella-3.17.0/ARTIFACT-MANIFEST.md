# Artifact Manifest

Generated 2026-11-02 by `tools/generate_manifest.rb`. It lists every file in this package (except this manifest) with its SHA-256, how it was produced, and its source.

- "Source checkout" means `public-tractus-x-umbrella` (Federity-X fork), branch `feat/BE-293-connector-bundle-and-portal-integration` @ `a5b07c5` plus its uncommitted working tree.
- "recovery/…" means this repository, branch `feat/BE-293-development` @ `df91837`.
- Copies marked "copied unchanged" were re-compared with their source by SHA-256 during generation: 64 compared, 0 mismatches.
- Re-check the package with `bash tools/verify_package.sh`, step 1.

| File | SHA-256 | Produced by | Source |
|---|---|---|---|
| `.gitignore` | `39b4c965f0ff2f779c584738c4c389145f48acc35bbbb0bdc02d753e22d34a00` | documentation | new |
| `BLOCKERS.md` | `6989b7bda9c331628b7c6a3182b9e76a387861889db9e7ea428c4435b1638718` | documentation | new |
| `COMPONENT-MATRIX.md` | `cd7e7a1d6d8109f4274b5ecd140bb3e31da4e6fd5a89dfe55576d15454ef3c02` | documentation | new |
| `DEPLOYMENT-CHECKLIST.md` | `f1a6177d0ccd6a4d697b8cb2d83b544a58ac44847e1cdf14bf59566701bec9d4` | documentation | new |
| `README.md` | `5ec928b0dde9af8340aab8a6f68b423aaf612dcadf3ab34ff19e3a6fd9c75b4e` | documentation | new |
| `chart/umbrella/.helmignore` | `c0b8b8fa7404e9c6991645067897e53c3c99d98529aa6a3b45c0bb0932df98ad` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/.helmignore (Git, commit 60c0b81) |
| `chart/umbrella/Chart.lock` | `66a92ee572da16b2698c3f1ca5e956bb63519c7e9429462148ecc210a9f61edc` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/Chart.lock (Git, commit 60c0b81) |
| `chart/umbrella/Chart.yaml` | `51646021596a89195017cbc59d9940468a534715ca4f5845f9c56d9ad0a84a0f` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/Chart.yaml (Git, commit 60c0b81) |
| `chart/umbrella/LICENSE` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/LICENSE (Git, commit 60c0b81) |
| `chart/umbrella/README.md` | `3dcd3bd75b224fd369f1c7c2d6d15d553f19e9bbd9dc2a2ff35f9fd63aa4b2f7` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/README.md (Git, commit 60c0b81) |
| `chart/umbrella/charts/bdrs-server-0.6.0.tgz` | `f7fe905a7d6eddebb3a04b8a4f3fd23777a4514cdba13577300d5836e5cec140` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/bdrs-server-0.6.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/bdrs-server-memory-0.6.0.tgz` | `2658dffb8188aa79b5f603276b2446e3f08689a6515a2e5e8ec9108b95b210b9` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/bdrs-server-memory-0.6.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/bpdm-6.2.0.tgz` | `f66be6a9ab115ac5c2bb95fe370abd45b6c1c5eb58c70625c33a3994bc6b17b4` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/bpdm-6.2.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/bpndiscovery-0.5.1.tgz` | `decad051f85fd196f0af7a86935d44f8737f35f443b7e2abc7a1af1ba1e607a8` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/bpndiscovery-0.5.1.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/centralidp-4.2.1.tgz` | `17ce0bfebb7b66653e24c165c62224e727e2f2ff255caf027e95f7d9ced45368` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/centralidp-4.2.1.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/cert-manager-v1.18.2.tgz` | `daddf7af7b1f0eaaa10edd790aefa0bd8c2b07830febf659460d843217f5b3c5` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/cert-manager-v1.18.2.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/discoveryfinder-0.5.1.tgz` | `a6ea70005200421157e09ec1d617ab2261ee9bb6a39469131b06eadcd46fb6ed` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/discoveryfinder-0.5.1.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/grafana-8.10.1.tgz` | `5ef0f0521036a65b0907ac3471057a816467e58bf98566700fc89fcae894de86` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/grafana-8.10.1.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/identity-and-trust-bundle-1.2.0.tgz` | `c763c8148cbf92637130cb2e22d73157e790ce8fde360b0213d0d01579a2e242` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/identity-and-trust-bundle-1.2.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/jaeger-3.0.7.tgz` | `3b6cac05277f806e4bf4ac57fb8bfeb969ac5ca568b728e8283aa75c4db4a6cf` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/jaeger-3.0.7.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/loki-6.27.0.tgz` | `7aca6e41a40872345e36e2495a9960216bcc2be7680aa526ba531ecb38f593ff` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/loki-6.27.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/opentelemetry-collector-0.126.0.tgz` | `3dbebae60c56b7397571f95997eb5df86f6fa08bd24317ea6985d19675a72141` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/opentelemetry-collector-0.126.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/pgadmin4-1.25.3.tgz` | `3ce2cc7e6a7f3a2715a1e975fc511478f8c30664b255caaac40ad8da4707b50c` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/pgadmin4-1.25.3.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/portal-2.6.0.tgz` | `a17ab65070eeea3e719e2187213db23fc9226f6a8b2fc94ed771ec6835ad1e09` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/prometheus-27.1.0.tgz` | `d12ad4ce178eb8c75b84bdf78d548495090e09717bbc02ca5ff01a08f97894bd` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/prometheus-27.1.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/sdfactory-2.1.35.tgz` | `de385253a77815cac15d0afd0052bd30dc32168732d9ee9eb42b100e060f455d` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/sdfactory-2.1.35.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/semantic-hub-0.5.0.tgz` | `5ab22c5b6b8d30c885bd0542ce366700a8d712266a0fbae3371537a5e18c402d` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/semantic-hub-0.5.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/sharedidp-4.2.1.tgz` | `0cad40f103096510d97376be4cebd1b9f665458db8cb5a85302a40e823213f23` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/sharedidp-4.2.1.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/ssi-credential-issuer-1.4.0.tgz` | `b3e7b24587a626c0d862d5893ffbafc3b76deeccec043200e3bccf3e06bf34ae` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/ssi-credential-issuer-1.4.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/tractusx-identityhub-memory-v0.3.2.tgz` | `db0272e6e073fed9e481345c3ae2d8ee5f5696b2bf5a8ebe846059a1ff50b45c` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/tractusx-identityhub-memory-v0.3.2.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/tractusx-identityhub-v0.3.2.tgz` | `701a26264eb413519d760f6f8a04f316e786f965f0cb98802ee644f805abd0f4` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/tractusx-identityhub-v0.3.2.tgz (Git, commit 60c0b81) |
| `chart/umbrella/charts/tx-data-provider-0.5.0.tgz` | `73a9ef4afbb011214d17fe0722a26fdc1f752e62625b9a5fcaef40f040bdb995` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/charts/tx-data-provider-0.5.0.tgz (Git, commit 60c0b81) |
| `chart/umbrella/cluster-issuer.yaml` | `57da22e7ac828a4bbdd64991b0fc29f71adcd5ef35adb15cc15bd50f5a2b07c3` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/cluster-issuer.yaml (Git, commit 60c0b81) |
| `chart/umbrella/files/be293-bdrs-vault-provision.sh` | `626ae15c04aa4162df9f5beb6f44f29b97f874284fe4c244053a1a867bece36c` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/files/be293-bdrs-vault-provision.sh (Git, commit 60c0b81) |
| `chart/umbrella/resources/grafana-dashboard.json` | `ebdf3774fc318d5cb139af2f4fff2abc2e9f1c692dae0aca0514ce3d939915da` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/resources/grafana-dashboard.json (Git, commit 60c0b81) |
| `chart/umbrella/templates/_helpers.tpl` | `c7de44c612db5c6212803d7b9bcb8347f007a0e6b07a377176b0cb05780c81dd` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/_helpers.tpl (Git, commit 60c0b81) |
| `chart/umbrella/templates/_wallet-derive.tpl` | `de935432e6fe3345864ae6fc8a28e3820ed55a76cf3051613acb2adb62123289` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/_wallet-derive.tpl (Git, commit 60c0b81) |
| `chart/umbrella/templates/_wallet-validate.tpl` | `f9c040b5d0d21e02da2acc98150c3ff19547407126b3c17bb8181a6635b64d35` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/_wallet-validate.tpl (Git, commit 60c0b81) |
| `chart/umbrella/templates/ca-issuer.yaml` | `74eed303061fe4d53d68edb0bc19abfce98ced551299514445a639139018c424` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/ca-issuer.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/configmap-bdrs-provision.yaml` | `eee143c021bb1a2834ddd8a25ef563f2d3e6581f1a99e53b07016e77f60d1001` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/configmap-bdrs-provision.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/configmap-portal-testdata-seeding.yaml` | `57a3f25799b34c6f66a1ba246b1ce914ba17bba3cc1fa63bb1fe7552b17f6c28` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/configmap-portal-testdata-seeding.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/configmap-wallet-mode.yaml` | `42457c0f69c226d7e73db202b0d75dcc1ec829bc5a2d607a505cfeae2bd37ee9` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/configmap-wallet-mode.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/didweb-resolver.yaml` | `da3929a99716f76a52a2c39a8a0509eb26d48dfa94a814c41c5e6f71cf34b0c4` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/didweb-resolver.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/fake-external-secrets.yaml` | `8bfbf89394f1353d09dffd5523cf4305d7f1698c3b05c3b5c299b5efa4cb848d` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/fake-external-secrets.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/fake-secretstore.yaml` | `a89fa9a83cba841d80aed31674adc38451ac7182798076c1f00ea9a215f407bc` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/fake-secretstore.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/grafana-dashboards.yaml` | `aa37888ee95916f7e84a56cf4c9955996c7cf4b139f7c51d4d6c289142f1b733` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/grafana-dashboards.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/networkpolicy-bdrs-vault.yaml` | `12a6a7e36436506cdce1b1c33a08c540461eb80a47f52f6c59e3524ad5427a10` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/networkpolicy-bdrs-vault.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/post-install-bdrs-setup.yaml` | `1348b1302c7676f17f37b35e5dfba388a9581f320b9f8b38f8b231e5df98bc2f` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/post-install-bdrs-setup.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/post-install-coredns-tx-test-patch.yaml` | `ad227a19a5dff04f897742ab6d516a20344c657d664f9d52bd129bc53dd7fe8f` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/post-install-coredns-tx-test-patch.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/smtp-deployment.yaml` | `8bc0146239fb5708d96ffda141d5e2a2c71f6db23d7ab2c762f0f39acf278291` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/smtp-deployment.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/smtp-ingress.yaml` | `0811c3ed300efa0a635fd2591e36fa2f0250420e2692fbdfc6dd1e3fa6b6d7ee` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/smtp-ingress.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/smtp-service.yaml` | `9cceb4b3a2261f557db69b5287377f31c39e3f612d932a1baf3ca9453ab91e3f` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/smtp-service.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/vault-external-secrets.yaml` | `b09e3b15047fb87e159fe7e52d83e72ad4fdd3bc20e0768b129a289d2970596b` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/vault-external-secrets.yaml (Git, commit 60c0b81) |
| `chart/umbrella/templates/vault-secretstore.yaml` | `3368090c822df65c5c8c843773f9dbf4ebcda6f77555c2b7a64b332d380a64a1` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/templates/vault-secretstore.yaml (Git, commit 60c0b81) |
| `chart/umbrella/values.yaml` | `58a21ca82950a4575723b8ff1532e188ee8a9628ad959fabe0764c6c8eec633d` | copied unchanged | recovery/be293-dev-3.17.0/chart/umbrella/values.yaml (Git, commit 60c0b81) |
| `charts/umbrella-infrastructure/.helmignore` | `bb987e6a8ef45a99255d1d632812482d5f0f3255ea841520b4d90342df5fe2b3` | copied unchanged | source checkout charts/umbrella-infrastructure/.helmignore (tracked @ a5b07c5) |
| `charts/umbrella-infrastructure/Chart.lock` | `97b5fe944bc1348f5001e0c591a5c799f132eacfc45faf8ba553b1fca4353dd0` | copied unchanged | source checkout charts/umbrella-infrastructure/Chart.lock (untracked) |
| `charts/umbrella-infrastructure/Chart.yaml` | `98ed45f05eccd98fd1a30e1704f84826e5e54d41dfe7a6eba11a4232632a2f6e` | copied unchanged | source checkout charts/umbrella-infrastructure/Chart.yaml (tracked @ a5b07c5) |
| `charts/umbrella-infrastructure/charts/external-secrets-0.18.2.tgz` | `5d0645b815837af4ce1fd0436879e4adfe8230072103c65429c4a41d9e00f43d` | copied unchanged | source checkout charts/umbrella-infrastructure/charts/external-secrets-0.18.2.tgz (untracked) |
| `charts/umbrella-infrastructure/charts/vault-0.30.1.tgz` | `a52b3b16aa9afae2deeb3d63500578a62c3daa777551f2c5eb6c2cd07bfd79cc` | copied unchanged | source checkout charts/umbrella-infrastructure/charts/vault-0.30.1.tgz (untracked) |
| `charts/umbrella-infrastructure/values.yaml` | `d476bcfd5b8de4fc358eddcb6db737be0673325b82bcb3480803b707bea16be5` | copied unchanged | source checkout charts/umbrella-infrastructure/values.yaml (tracked @ a5b07c5) |
| `docs/ISOLATED-CLUSTER-TEST-PLAN.md` | `41e62b9f6e8579e5f9993a21791c6da89de173b97ede5642e6afea64bde9747a` | documentation | new |
| `docs/SECRETS.md` | `2bc16324eacb20d3cfba65c4770c318894eac4a327912fb8529952909bc011e3` | documentation | new |
| `docs/VAULT-CONTRACT.md` | `9fbe32054a2daeaab809549a85d83d1ffc9cf47d3b4ff3aad56a0a20b6a90b20` | documentation | new |
| `inventory/IMAGE-INVENTORY.yaml` | `8bbfbab9673a463adc7557bc5844859dc3a92cadafccf91fb3b05f0aa475e754` | authored; registry sanitized | live pod imageIDs, revision 21 manifest, source checkout publication manifest and lock files |
| `inventory/expected-rev21-inventory.json` | `e0de7000a7e3f9957fc7faa3a6ec7efa4fe8fd96ef254212d74225db2c4b2629` | generated; no values | helm get manifest + hooks be293-app revision 21 (read-only) | tools/render_inventory.rb --normalize-registry |
| `inventory/expected-vault-inventory.json` | `b646eed5220ea11cb822da54ff750d0cbb3afc1bb085285c26de09ae38225c88` | generated; no values | helm get manifest + hooks be293-vault revision 1 (read-only) | tools/render_inventory.rb |
| `manifests/10-ingress-identityhub-legacy-did.yaml` | `8b7d3540717d0f8ce70cbef73c817fb28b68c46690be47cbb8bb0a44abf6608c` | reconstructed; domain sanitized; equals live | live Ingress be293/be293-identityhub-legacy-did (read-only, 2026-11-02) |
| `manifests/11-ingress-identityhub-did-documents.yaml` | `9e51cdde55358d3cfa1fc34964ed4c8249151f5826e89399e4a0a456368d0725` | copied; domain sanitized; equals live | source checkout hack/manifests/be293-identityhub-did-documents-ingress.yaml (untracked) |
| `manifests/12-ingress-issuer-legacy-did.yaml` | `a5c86ef30132f120161dc4a8b6d6a3af9c69c03005e9c707af2d0de9cc63015c` | reconstructed; domain sanitized; equals live | live Ingress be293/be293-issuer-legacy-did (read-only, 2026-11-02) |
| `manifests/13-ingress-issuer-statuslist.yaml` | `8510cf8b6bf7b4e45e1c99e32748035b1d8b1ca832903a350b6403cbae4ecbef` | copied; domain sanitized; equals live | source checkout hack/manifests/be293-issuer-statuslist-ingress.yaml (tracked) |
| `tools/apply_environment.rb` | `59408028a666fdefd8b37cccc0e1b0f2e13035e869680aa504a0950b1b82ee91` | copied unchanged | recovery/be293-dev-3.17.0/tools/apply_environment.rb (Git) |
| `tools/check_placeholders.rb` | `43314d2686b2d9cc1c251ba0040e6351018df4d60b0451cfb44b89a59cdbd5ae` | tooling | new |
| `tools/compare_inventory.rb` | `c50c4c6fa429cefbb567ff5e9c2bd1edab44682664a297a1d28637ef24041ca5` | tooling | new |
| `tools/envnames.rb` | `cdbe869f0f883182866e66775707dbeaf369df2ed31d9b2f7a734e1b4d8a0571` | copied unchanged | recovery/be293-dev-3.17.0/tools/envnames.rb (Git) |
| `tools/generate_manifest.rb` | `88d2ace2ab1848c7c99b3782ee22965bc764cdfd07d931355d0e574a018b6e8d` | tooling | new |
| `tools/inventory.rb` | `1d2abd52d36153bbf3694b27c8286059afc2f93e1fbd149dd68d5ce8b0ace9c8` | copied unchanged | recovery/be293-dev-3.17.0/tools/inventory.rb (Git) |
| `tools/make_synthetic_secrets.rb` | `f22fe33ae58b539d038a7090deb4fc844f6426b01ae418e6bc8a4d6cbebf5634` | tooling | new |
| `tools/objhash.rb` | `da2530db8db276353ab49e9ef2ba09960f90ec45eb272ad6dc18b8034a4ba1d0` | copied unchanged | recovery/be293-dev-3.17.0/tools/objhash.rb (Git) |
| `tools/render_inventory.rb` | `280a322487cc99c430104f2cb6961ec79c68bfc0dbd0b4d82d6dd65ff647767e` | tooling | new |
| `tools/scan.rb` | `daf74cf9b52e3a8ecaf436f63b3e047f7413cd22685358b8fc70f1f8b4c3e5c5` | copied unchanged | recovery/be293-dev-3.17.0/tools/scan.rb (Git) |
| `tools/secrets_example.rb` | `97dfbe0e80b2a4e5341cd52834bdb1a68d7445c217001b1e7ecd5e86f724a26e` | copied unchanged | recovery/be293-dev-3.17.0/tools/secrets_example.rb (Git) |
| `tools/verify_package.sh` | `0415a9e3aa9eb67ac712bad4e62d8d37dd396aa3e2c6b81896612f3c5ae9095b` | tooling | new |
| `values/values-be293-dev.example.yaml` | `3bf7eb3c40868169658bdfceca5ab9934722a88b34b92c0f76f59ba62b85d690` | copied unchanged | recovery/be293-dev-3.17.0/values/values-be293-dev.example.yaml (Git, commit 60c0b81) |
| `values/values-be293-dev.secrets.example.yaml` | `28271677fe77181ea124c8ecc1e8e94f5a26fcc6db582960f7864898feae03c2` | copied unchanged | recovery/be293-dev-3.17.0/values/values-be293-dev.secrets.example.yaml (Git, commit 60c0b81) |
| `values/values-be293-identityhub-superuser-secretref.yaml` | `19b10a252c858dfb1efc901ed7de98fbc7100f8651765adaa0d074ce4aefffcb` | new overlay (optional) | derived from source checkout charts/values-callback-activation.yaml and charts/umbrella/values-combined-portal-additions.yaml (working tree) |
| `values/values-be293-vault.example.yaml` | `3e6fc061ff94b625814623251c19556979d05dd5fb1cf73e7a6abc9fc22cb3b2` | copied; header comment added | source checkout charts/values-be293-vault-dev.yaml (untracked) |
