# lib/salva/metadata_import.rb
#
# Pure metadata normalisation for SALVA's DOI/PMID importer.
# INPUT : parsed Crossref JSON ("message" hash) OR PubMed esummary record hash.
# OUTPUT: a plain Hash whose keys match the Article form fields, plus
#         journal_name / issn used to look up an EXISTING Journal.
# No Rails, no ActiveRecord, no DB. Stdlib only. Ruby 2.1-compatible
# (no &., no Hash#dig, no squiggly heredocs) so this SAME file runs in SALVA.
module MetadataImport
  module_function

  MONTHS = { 'jan'=>1,'feb'=>2,'mar'=>3,'apr'=>4,'may'=>5,'jun'=>6,
             'jul'=>7,'aug'=>8,'sep'=>9,'oct'=>10,'nov'=>11,'dec'=>12 }

  def from_crossref(message)
    issued   = message['issued'] || {}
    parts    = (issued['date-parts'] || [[]])[0] || []
    titles   = message['title'] || []
    journals = message['container-title'] || []
    issns    = message['ISSN'] || []
    {
      'title'        => strip_s(titles[0]),
      'authors'      => crossref_authors(message['author'] || []),
      'year'         => parts[0],
      'month'        => parts[1],
      'vol'          => message['volume'],
      'num'          => message['issue'],
      'pages'        => normalize_pages(message['page']),
      'doi'          => message['DOI'],
      'url'          => message['URL'],
      'journal_name' => strip_s(journals[0]),
      'issn'         => issns[0]
    }
  end

  # PubMed esummary JSON: the per-uid record (result[uid]).
  def from_pubmed(rec)
    y, m = parse_pubdate(rec['pubdate'] || rec['epubdate'])
    issn = (rec['issn'] && !rec['issn'].to_s.empty?) ? rec['issn'] : rec['essn']
    {
      'title'        => strip_s(rec['title']).sub(/\.\z/, ''),
      'authors'      => pubmed_authors(rec['authors'] || []),
      'year'         => y,
      'month'        => m,
      'vol'          => rec['volume'],
      'num'          => rec['issue'],
      'pages'        => normalize_pages(rec['pages']),
      'doi'          => pubmed_doi(rec['articleids'] || []),
      'url'          => nil,
      'journal_name' => strip_s(rec['fulljournalname']),
      'issn'         => issn
    }
  end

  # ---- helpers ----
  def crossref_authors(authors)
    authors.map { |a|
      family = strip_s(a['family']); given = strip_s(a['given'])
      if    family.empty? then strip_s(a['name'])
      elsif given.empty?  then family
      else  family + ', ' + given end
    }.reject { |n| n.empty? }.join('; ')
  end

  def pubmed_authors(authors)
    authors.map { |a|
      name = strip_s(a['name'])            # e.g. "Concha L"
      i = name.rindex(' ')
      (i && i > 0) ? (name[0...i] + ', ' + name[(i+1)..-1]) : name
    }.reject { |n| n.empty? }.join('; ')
  end

  def pubmed_doi(ids)
    hit = ids.find { |x| (x['idtype'] || x['IdType']) == 'doi' }
    hit ? (hit['value'] || hit['Value']) : nil
  end

  def parse_pubdate(s)
    return [nil, nil] if s.nil?
    parts = s.to_s.split(/\s+/)
    y = (parts[0] && parts[0] =~ /\A\d{4}\z/) ? parts[0].to_i : nil
    m = (parts[1] ? MONTHS[parts[1][0,3].downcase] : nil)
    [y, m]
  end

  def normalize_pages(page)
    return nil if page.nil?
    page.to_s.strip.gsub(/\s*-\s*/, '-')
  end

  def strip_s(v); v.nil? ? '' : v.to_s.strip; end

  # Accepts a bare PMID ("40563343") or a PubMed URL
  # ("https://pubmed.ncbi.nlm.nih.gov/40563343/") and returns just the digits.
  def clean_pmid(value)
    value.to_s.scan(/\d+/).last
  end
end
