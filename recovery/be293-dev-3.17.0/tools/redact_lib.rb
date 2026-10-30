SENSITIVE_KEY = /(pass|secret|token|cred|private|pwd|jwk|pem|apikey|api[_-]?key|salt|signing|encryption|keystore|truststore|key$|privkey|clientsecret|dsn)/i
REF_KEY = /\A(existingSecret|existingSecretKey|secretName|name|key|passwordKey|adminPasswordKey|userPasswordKey|secretKeys|vaultTokenSecret|vaultTokenSecretKey|issuerAdminApiKeySecretKey|pullSecretName|keycloakServiceTlsCaSecret|keycloakServiceTlsCaKey|authKeyAlias|secret_alias|secretDelivery|tokenUrl|token_url|tokenUri|tokenAddress|walletTokenAddress|credentialServiceUrl|credentialServiceBaseAddress|TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL|TX_IAM_IATP_CREDENTIALSERVICE_URL|TX_PORTAL_CALLBACK_TOKEN_URL|jwkSetUri|bpnCredentialType|membershipCredentialType|bpnCredentialDefinitionId|membershipCredentialDefinitionId|credentialServiceParticipantContextIdEncoding|alias|paths)\z/
def payload?(path, v)
  return false unless v.is_a?(String) && !v.empty?
  last = path.last.to_s
  return false if path[-2].to_s == 'paths'
  return true if v.include?('-----BEGIN') || v =~ /eyJ[A-Za-z0-9_\-]{10,}\./
  return false if path.include?('secretKeyRef') || path.include?('secretKeys') || path.include?('valueFrom')
  return false if REF_KEY.match?(last) && (v =~ %r{\A(https?|jdbc|did):} || v =~ /\A[a-z0-9][a-z0-9.\-_\/]{0,62}\z/i && v.length < 40 && v !~ /[A-Z].*[0-9]|[0-9].*[A-Z]/)
  SENSITIVE_KEY.match?(last) || (v.length >= 24 && v =~ /\A[A-Za-z0-9+\/=_\-.]+\z/ && v =~ /[0-9]/ && v =~ /[A-Z]/ && v =~ /[a-z]/ && v !~ /\A(did|https?):|@sha256:|sha256:/)
end
def scrub(o, path = [], hits = [])
  case o
  when Hash then o.each_with_object({}) { |(k, v), h| h[k] = scrub(v, path + [k], hits) }
  when Array then o.each_with_index.map { |v, i| scrub(v, path + [i], hits) }
  else
    if payload?(path, o) then hits << path.join('.'); "REDACTED-PLACEHOLDER" else o end
  end
end
