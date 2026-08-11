# lib/salva/metadata_fetcher.rb
#
# Thin HTTP client: identifier -> parsed JSON for MetadataImport.
# Stdlib only (net/http, json). Ruby 2.1-compatible. Isolated so it can be
# stubbed in tests and so the offline normaliser specs never touch the network.
require 'net/http'
require 'uri'
require 'json'

module MetadataFetcher
  module_function

  CROSSREF = 'https://api.crossref.org/works/'
  EUTILS   = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi'

  # -> Crossref "message" hash, or nil on any failure.
  def crossref(doi, opts = {})
    body = get(CROSSREF + doi.to_s, opts)      # Crossref accepts the raw DOI in the path
    body ? JSON.parse(body)['message'] : nil
  rescue StandardError
    nil
  end

  # -> PubMed esummary record hash for the pmid, or nil.
  def pubmed(pmid, opts = {})
    q = { 'db' => 'pubmed', 'id' => pmid.to_s, 'retmode' => 'json',
          'tool' => opts[:tool], 'email' => opts[:email], 'api_key' => opts[:api_key] }
    query = q.reject { |_, v| v.nil? || v.to_s.empty? }
             .map { |k, v| k + '=' + URI.encode_www_form_component(v) }.join('&')
    body = get(EUTILS + '?' + query, opts)
    return nil unless body
    res = (JSON.parse(body)['result'] || {})
    res[pmid.to_s]
  rescue StandardError
    nil
  end

  def get(url, opts = {})
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = opts[:timeout] || 10
    http.read_timeout = opts[:timeout] || 10
    req = Net::HTTP::Get.new(uri.request_uri)
    req['User-Agent'] = opts[:user_agent] || 'SALVA-importer (mailto:library@example.org)'
    resp = http.request(req)
    resp.is_a?(Net::HTTPSuccess) ? resp.body : nil
  end
end
