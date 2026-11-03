# Fail-closed checks on a rendered be293-target manifest stream (stdin). It complements the
# render-time chart guard by checking what Helm actually produced. Exit 1 on any finding.
# Prints object kinds/names and rule names only, never values of Secrets.
#
# Usage: helm template ... | ruby tools/check_target_render.rb <values-be293-target.private.yaml> [--vault]
#   --vault  the stream is the be293-vault release (only the namespace and storage rules apply)
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
require 'yaml'

values_file = ARGV.find { |a| !a.start_with?('--') }
vault_only = ARGV.include?('--vault')
abort 'usage: ... | check_target_render.rb <values-be293-target.private.yaml> [--vault]' unless values_file
target = YAML.safe_load(File.read(values_file)).dig('be293', 'target') || abort('no be293.target in values file')
namespace = target.fetch('namespace')
text = $stdin.read
# Template comments (e.g. the local-profile explanations) are not configuration.
body = text.lines.reject { |l| l.lstrip.start_with?('#') }.join
docs = YAML.load_stream(text).select { |d| d.is_a?(Hash) && d['kind'] }
abort 'empty render' if docs.empty?
findings = []
id = ->(d) { "#{d['kind']}/#{d.dig('metadata', 'name')}" }

# Storage: the cluster default StorageClass must provision every claim. Any storageClassName,
# including "" (which disables dynamic provisioning), is a finding.
claims = 0
docs.each do |d|
  templates = d['kind'] == 'PersistentVolumeClaim' ? [d] : (d.dig('spec', 'volumeClaimTemplates') || [])
  templates.each do |c|
    claims += 1
    findings << "#{id.(d)}: claim #{c.dig('metadata', 'name')} sets storageClassName" if (c['spec'] || {}).key?('storageClassName')
  end
end

docs.each do |d|
  ns = d.dig('metadata', 'namespace')
  findings << "#{id.(d)}: namespace #{ns}" if ns && ns != namespace
end
%w[ClusterRole ClusterRoleBinding Namespace StorageClass CustomResourceDefinition ClusterIssuer].each do |k|
  docs.select { |d| d['kind'] == k }.each { |d| findings << "#{id.(d)}: cluster-scoped object" }
end

{ 'example.invalid' => 'example domain', '.tx.test' => 'local .tx.test name', '<<SET-' => 'placeholder',
  'synthetic-' => 'synthetic test credential', 'premium-perf1-stackit' => 'DEV StorageClass',
  'letsencrypt-dev' => 'DEV ClusterIssuer', 'be293-dockerhub-pull' => 'DEV pull Secret' }.each do |marker, rule|
  n = body.scan(marker).size
  findings << "render contains #{rule} (#{n}x)" if n.positive?
end

unless vault_only
  zone = target.fetch('dnsZone')
  ingresses = docs.select { |d| d['kind'] == 'Ingress' }
  expected = %w[be293-identityhub-legacy-did be293-identityhub-did-documents be293-issuer-legacy-did be293-issuer-statuslist]
  missing = expected - ingresses.map { |d| d.dig('metadata', 'name') }
  findings << "missing external Ingresses: #{missing.join(', ')}" unless missing.empty?
  ingresses.each do |d|
    findings << "#{id.(d)}: ingressClassName" unless d.dig('spec', 'ingressClassName') == target.fetch('ingressClass')
    issuer = (d.dig('metadata', 'annotations') || {})['cert-manager.io/cluster-issuer']
    findings << "#{id.(d)}: ClusterIssuer" if issuer && issuer != target.fetch('clusterIssuer')
    hosts = (d.dig('spec', 'rules') || []).map { |r| r['host'] } + (d.dig('spec', 'tls') || []).flat_map { |t| t['hosts'] }
    hosts.reject { |h| h.end_with?(".#{zone}") }.each { |h| findings << "#{id.(d)}: host outside dnsZone (#{h})" }
  end
  findings << 'no Ingress requests a certificate from the ClusterIssuer' if ingresses.none? { |d| (d.dig('metadata', 'annotations') || {}).key?('cert-manager.io/cluster-issuer') }

  repository = target.fetch('imageRepository')
  private_images = text.scan(/image:\s*["']?([^\s"']+)/).flatten.select { |i| i.include?('/be293-images') }.uniq
  private_images.reject { |i| (i.start_with?("#{repository}:") || i.start_with?("#{repository}@")) && i.include?('@sha256:') }.each { |i| findings << "private image not pinned to imageRepository by digest: #{i}" }
  findings << 'no private BE-293 image found' if private_images.empty?
  pull = text.scan(/imagePullSecrets:\s*\n\s*-\s*name:\s*["']?([a-z0-9-]+)/).flatten.uniq
  (pull - [target.fetch('pullSecretName')]).each { |p| findings << "unexpected imagePullSecret #{p}" }
  puts "ingresses=#{ingresses.size} private-images=#{private_images.size} pull-secrets=#{pull.join(',')}"
end

puts "objects=#{docs.size} claims=#{claims} findings=#{findings.size}"
findings.each { |f| puts "FINDING #{f}" }
exit(findings.empty? ? 0 : 1)
