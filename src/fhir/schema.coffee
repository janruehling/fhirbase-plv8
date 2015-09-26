sql =  require('../honey')
namings = require('./namings')
utils = require('./utils')
pg_meta = require('./pg_meta')

exports.create_table = (plv8, resource_type)->
  nm = namings.table_name(plv8, resource_type)
  if pg_meta.table_exists(plv8, nm)
    {status: 'error', message: "Table #{nm} already exists"}
  else
    utils.exec(plv8, create: "table", name: nm, inherits: ['resource'])
    plv8.execute "alter table #{nm} ALTER column resource_type SET DEFAULT '#{resource_type}'"

    utils.exec(plv8, create: "table", name: ['history', nm],  inherits:  ['history.resource'])
    plv8.execute "alter table history.#{nm} ALTER column resource_type SET DEFAULT '#{resource_type}'"
    {status: 'ok', message: "Table #{nm} was created"}

exports.drop_table = (plv8, nm)->
  nm = namings.table_name(plv8, nm)
  unless pg_meta.table_exists(plv8, nm)
    {status: 'error', message: "Table #{nm} not exists"}
  else
    utils.exec(plv8, drop: "table", name: nm, safe: true)
    utils.exec(plv8, drop: "table", name: ['history',nm], safe: true)
    {status: 'ok', message: "Table #{nm} was dropped"}

exports.describe_table = (plv8, resource_type)->
  nm = namings.table_name(plv8, resource_type)
  columns = utils.exec plv8,
    select: [':column_name', ':dtd_identifier']
    from: ['information_schema.columns']
    where: [':and',[':=',':table_name', nm]
                   [':=', ':table_schema', 'public']]
  name: nm
  columns: columns.reduce(((acc, x)-> acc[x.column_name] = x; delete x.column_name; acc),{})
