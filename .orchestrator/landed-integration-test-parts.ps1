function Get-LandedIntegrationPartSelection([string]$Part, [bool]$AuthorityOnly, [bool]$OwnershipOnly, [bool]$ProductCensusOnly) {
  if ($Part -cne 'all' -and ($AuthorityOnly -or $OwnershipOnly -or $ProductCensusOnly)) {
    throw 'Named parts cannot be combined with legacy partial selectors'
  }
  if ($Part -cnotin @('all','product-census','authority','dispatch','collector','ownership')) { throw 'Unknown landed integration part' }
  return [pscustomobject]@{
    productCensus = ($Part -cin @('all','product-census') -and ($ProductCensusOnly -or (-not $AuthorityOnly -and -not $OwnershipOnly)))
    authority = ($Part -cin @('all','authority') -and -not $OwnershipOnly)
    dispatch = ($Part -cin @('all','dispatch') -and -not $AuthorityOnly -and -not $OwnershipOnly)
    collector = ($Part -cin @('all','collector') -and -not $AuthorityOnly -and -not $OwnershipOnly)
    ownership = ($Part -cin @('all','ownership') -and (-not $AuthorityOnly -or $OwnershipOnly))
  }
}
