# Search and indexing nested elements

    sql = require('../honey')
    lang = require('../lang')
    xpath = require('./xpath')
    search_common = require('./search_common')

    paths = {
      "patient.given"  : "\"tbl1\".resource->'name'->0->'given'->0",
      "patient.family" : "\"tbl1\".resource->'name'->0->'family'->0",
      "patient.birthdate" : "\"tbl1\".resource->'birthDate'",
      "practitioner.given"  : "\"tbl1\".resource->'name'->'given'->0",
      "practitioner.family" : "\"tbl1\".resource->'name'->'family'->0",
      "location.name" : "\"tbl1\".resource->>'name'"
    }

    exports.order_expression = (tbl, meta)->
      elem = meta.name
      expression = paths[elem]
      if meta.operator == "desc"
        expression += " DESC"
      ['$raw', expression]

    exports.order_expression.plv8_signature =
      arguments: ['text', 'json']
      returns: 'json'
      immutable: true
