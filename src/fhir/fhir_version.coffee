fhir_version = -> '1.3.1-kainos'

exports.fhir_version = fhir_version

exports.fhir_version.plv8_signature = {
  arguments: 'json'
  returns: 'varchar(20)'
  immutable: true
}
