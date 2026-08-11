# spec/lib/metadata_import_spec.rb
# Pure normaliser specs -- no Rails, no DB. Run anywhere:
#   bundle exec rspec spec/lib/metadata_import_spec.rb
require 'json'
require File.expand_path('../../../lib/salva/metadata_import', __FILE__)

FIX = File.expand_path('../../fixtures', __FILE__)

describe MetadataImport do
  it 'maps a Crossref record onto Article fields' do
    msg = JSON.parse(File.read(File.join(FIX, 'crossref', 'neuroimage.json')))['message']
    r = MetadataImport.from_crossref(msg)
    expect(r['title']).to        eq('Diffusion tensor imaging of the human brain')
    expect(r['authors']).to      eq('Concha, Luis; Doe, Jane')
    expect(r['year']).to         eq(2012)
    expect(r['month']).to        eq(8)
    expect(r['vol']).to          eq('62')
    expect(r['num']).to          eq('3')
    expect(r['pages']).to        eq('1204-1215')
    expect(r['doi']).to          eq('10.1016/j.neuroimage.2012.03.072')
    expect(r['journal_name']).to eq('NeuroImage')
    expect(r['issn']).to         eq('1053-8119')
  end

  it 'maps a PubMed esummary record and extracts the DOI' do
    rec = JSON.parse(File.read(File.join(FIX, 'pubmed', 'sample.json')))
    r = MetadataImport.from_pubmed(rec)
    expect(r['title']).to        eq('Diffusion tensor imaging of the human brain')
    expect(r['authors']).to      eq('Concha, L; Doe, J')
    expect(r['year']).to         eq(2012)
    expect(r['month']).to        eq(8)
    expect(r['doi']).to          eq('10.1016/j.neuroimage.2012.03.072')
    expect(r['journal_name']).to eq('NeuroImage')
  end

  it 'leaves month nil when Crossref gives only a year' do
    msg = JSON.parse(File.read(File.join(FIX, 'crossref', 'no_month.json')))['message']
    r = MetadataImport.from_crossref(msg)
    expect(r['year']).to  eq(2019)
    expect(r['month']).to be_nil
  end

  it 'handles a single Crossref author with no trailing separator' do
    msg = JSON.parse(File.read(File.join(FIX, 'crossref', 'single_author.json')))['message']
    r = MetadataImport.from_crossref(msg)
    expect(r['authors']).to eq('Lopez, Maria')
  end

  it 'maps a Crossref book chapter (no ISSN, container-title is the book title)' do
    msg = JSON.parse(File.read(File.join(FIX, 'crossref', 'book_chapter.json')))['message']
    r = MetadataImport.from_crossref(msg)
    expect(r['title']).to        eq('A chapter with no ISSN, only ISBN')
    expect(r['authors']).to      eq('Ruiz, Carlos')
    expect(r['journal_name']).to eq('Handbook of Examples')
    expect(r['issn']).to         be_nil
    expect(r['vol']).to          be_nil
  end

  it 'cleans a PMID from a bare number' do
    expect(MetadataImport.clean_pmid('40563343')).to eq('40563343')
  end

  it 'cleans a PMID from a pubmed.ncbi.nlm.nih.gov URL' do
    expect(MetadataImport.clean_pmid('https://pubmed.ncbi.nlm.nih.gov/40563343/')).to eq('40563343')
  end

  it 'cleans a PMID from a URL with no trailing slash and surrounding whitespace' do
    expect(MetadataImport.clean_pmid('  https://pubmed.ncbi.nlm.nih.gov/40563343  ')).to eq('40563343')
  end

  it 'returns nil for a blank PMID' do
    expect(MetadataImport.clean_pmid('')).to be_nil
    expect(MetadataImport.clean_pmid(nil)).to be_nil
  end
end
