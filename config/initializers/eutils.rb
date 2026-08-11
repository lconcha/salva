# Optional NCBI E-utilities politeness settings for the DOI/PMID importer
# (PMID lookups only -- Crossref/DOI needs none of this). See
# config/eutils.yml.example. Falls back to {} if config/eutils.yml is absent.
EUTILS_CONFIG = begin
  YAML.load_file(Rails.root.join('config', 'eutils.yml'))[Rails.env] || {}
rescue Errno::ENOENT
  {}
end
