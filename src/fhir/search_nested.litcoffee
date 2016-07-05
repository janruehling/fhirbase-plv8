# Search and indexing nested elements

    sql = require('../honey')
    lang = require('../lang')
    xpath = require('./xpath')
    search_common = require('./search_common')

    paths = {
      "patient.given"  : "resource->'name'->0->'given'->0",
      "patient.family" : "resource->'name'->0->'family'->0",
      "patient.birthdate" : "resource->'birthDate'",
      "practitioner.given"  : "resource->'name'->'given'->0",
      "practitioner.family" : "resource->'name'->'family'->0",
      "location.name" : "resource->>'name'"
    }

    exports.order_expression = (tbl, meta)->
      elem = meta.name
      expression = tbl+"."+paths[elem]
      if meta.operator == "desc"
        expression += " DESC"
      ['$raw', expression]

    exports.order_expression.plv8_signature =
      arguments: ['text', 'json']
      returns: 'json'
      immutable: true
