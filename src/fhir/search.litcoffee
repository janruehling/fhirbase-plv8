FHIRbase search implementation
====


This module is responsible for FHIR search implementation.

Search API is specified on

* [http://hl7-fhir.github.io/search.html]
* [http://hl7-fhir.github.io/search_filter.html]

pages.

This is a most sofistiacted part of fhirbase,
so the code split as much as possible  into small modules

`query_string` module parse query string into {query: 'ResourceType', where: [params], joins: [params]} form
`expand_params` walk throw it and add required FHIR meta-data to each parameter
`normalize_operators` unify operators

    compat = require('../compat')
    expand = require('./expand_params')
    helpers = require('./search_helpers')
    index = require('./meta_index')
    lang = require('../lang')
    lisp = require('../lispy')
    meta_db = require('./meta_pg')
    namings = require('../core/namings')
    namings = require('../core/namings')
    outcome = require('./outcome')
    parser = require('./query_string')
    pg_meta = require('../core/pg_meta')
    sql = require('../honey')
    utils = require('../core/utils')

For every search type we have dedicated module,
with indexing and building search expression implementation.

Every module implements and exports `handle(table_name, meta, value)` function,
which should generate honey sql predicate expression.

Such expressions usualy contains some `extract` function, because we have to extract
appropriate elements from resource by path


    SEARCH_TYPES_TABLE =
      string: require('./search_string')
      token: require('./search_token')
      reference: require('./search_reference')
      date: require('./search_date')
      number: require('./search_number')
      quantity: require('./search_quantity')
      uri: require('./search_uri')


    DEFAULT_RESOURCES_PER_PAGE = 10

    special_resource_types = {
      "practitioner"  : "'participant'",
      "location" : "'location'->0->'location'"
    }
This is main function:

@param query [Object]
 query.resourceType
 query.queryString - original query string for search

function return [SearchBundle](http://hl7-fhir.github.io/bundle.html)

Initially we need to initialize index with FHIR metainformation.
We need to look-up this index to resolve search parameter type, path and element type.

Then we are building sql query as honeysql  datastructure
(see _search_sql implementation).

If number of results is equal to our limit, we have to execute
another query for potential results count.

Then we are returning  resulting Bundle.

    search_include = require('./search_include')
    search_elements = require('./search_elements')

    mask_resources = (plv8, expr, idx_db, resources)->
      sel = if expr.elements
        search_elements.paths_to_selector(expr.elements)
      else if expr.summary
        idx_db.summary_selector(expr.query)
      else
        throw new Error("Unexpected guard")

      resources.map((res)-> search_elements.elements(res, sel))

    exports.fhir_search = (plv8, query)->
      if query.resourceType &&
         !pg_meta.table_exists(
           plv8,
           namings.table_name(plv8, query.resourceType)
         )
        return outcome.unknown_type(query.resourceType)

      idx_db = ensure_index(plv8)

      res = _search_sql(plv8, idx_db, query)
      honey = res.hsql
      expr = res.query

      resource_rows = utils.exec(plv8, honey)
      resources = resource_rows.map((x)-> compat.parse(plv8, x.resource))

      should_include_total = (expr.total_method != "no")

      if should_include_total
        count = get_count(plv8, honey, expr)

      base_url = "#{query.resourceType}/#{query.queryString}"

      if expr.summary or expr.elements
        resources = mask_resources(plv8, expr, idx_db, resources)

      if expr.include && (count > 0 || !should_include_total)
        includes = search_include.load_includes(plv8, expr.include, resources)
        resources = resources.concat(includes)

      if expr.revinclude && (count > 0 || !should_include_total)
        includes = search_include.load_revincludes(plv8, expr.revinclude, resources)
        resources = resources.concat(includes)

      if should_include_total
        resourceType: 'Bundle'
        type: 'searchset'
        total: count
        link: helpers.search_links(query, expr, count)
        entry: resources.map(to_entry)
      else
        resourceType: 'Bundle'
        type: 'searchset'
        entry: resources.map(to_entry)


Helper function to convert resource into entry bundle:
TODO: add links

    to_entry = (resource)->
      resource: helpers.postprocess_resource(resource)

This function should be visible from postgresql, so
we have to describe it signature:

    exports.fhir_search.plv8_signature = ['json', 'json']


Building SQL from search parameters

To build search query we need to

    normalize_operators = (expr)->
      forms =
        $param: (metas, value)->
          for meta in metas
            handler = SEARCH_TYPES_TABLE[meta.searchType]

            unless handler
              throw new Error("NORMALIZE: Not registered search type [#{meta.searchType}]")

            unless handler.normalize_operator
              throw new Error("NORMALIZE: Not implemented noramalize_operator for [#{meta.searchType}]")

            meta.operator = if meta.modifier == 'asc' or meta.modifier == 'desc'
                meta.modifier
              else
                handler.normalize_operator(meta, value)

            delete meta.modifier
            delete value.prefix

          ['$param', metas, value]

      lisp.eval_with(forms, expr)


    merge_where = (hsql, expr)->
      if hsql.where
        if hsql.where[0] == '$and'
          hsql.where.push(expr)
        else
          hsql.where = ['$and', hsql.where, expr]
      else if not hsql.where
        hsql.where = expr
      hsql

    _order_sql = (plv8, idx, query)->
      unless query.resourceType
        throw new Error("Expected query.resourceType attribute")

      next_alias = mk_alias()

      alias = next_alias()

      expr = parser.parse(query.resourceType, query.queryString || "")
      expr = expand.expand(idx, expr)
      expr = normalize_operators(expr)

      ordering = ''
      if expr.sort
        ordering = order_hsql(alias, expr.sort)

      hsql =
        select: sql.raw(alias + '.*')
        from: ['$alias', ['$q', "#{namings.table_name(plv8, expr.query)}"], alias]
        where: expr.where
        order: ordering

      if expr.joins
        hsql.join = lang.mapcat expr.joins, (x)->
          mk_join(plv8, alias, next_alias, x)

      {hsql: hsql, query: expr}

    _search_sql = (plv8, idx, query)->
        unless query.resourceType
          throw new Error("Expected query.resourceType attribute")
        next_alias = mk_alias()
        alias = next_alias()
        expr = parser.parse(query.resourceType, query.queryString || "")
        expr = expand.expand(idx, expr)
        expr = normalize_operators(expr)
        nested_order = expr.sort && is_nested_order(expr.sort)
        table_name = namings.table_name(plv8, expr.query)
        if nested_order == true
            for where_elem in expr.where
                if Array.isArray(where_elem)
                    param_obj = where_elem[1]
                    param_obj[0].isNested = true;

        expr.where = to_hsql(alias, expr.where)
        if expr.ids
          expr = merge_where(expr, ['$in', ":#{alias}.id", expr.ids])

        if expr.lastUpdateds
          for lastUpdated in expr.lastUpdateds
            expr = merge_where(
              expr,
              [
                '$&&',
                [
                  '$raw',
                  '''
                  tstzrange(
                    updated_at,
                    (updated_at + INTERVAL '1 millisecond'),
                    '[)'
                  )
                  '''
                ],
                SEARCH_TYPES_TABLE.date.value_to_range(
                  lastUpdated.operator,
                  lastUpdated.value
                )
              ]
            )

        if expr.sort && !is_nested_order(expr.sort)
          ordering = order_hsql(alias, expr.sort)

        if expr.sort && is_nested_order(expr.sort)
          nested_table_alias = next_alias()
          ordering = order_hsql(nested_table_alias, expr.sort)
          nested_order_query = get_nested_order_query(expr, alias, nested_table_alias, table_name)
          hsql =
            select: nested_order_query.select,
            from: nested_order_query.from,
            join: nested_order_query.join,
            where: nested_order_query.where,
            order: ordering
        else
          hsql =
              select: sql.raw(alias + '.*')
              from: ['$alias', ['$q', "#{namings.table_name(plv8, expr.query)}"], alias]
              where: expr.where
              order: ordering

        if expr.count != null || expr.page != null
          hsql.limit = expr.count || DEFAULT_RESOURCES_PER_PAGE

        if expr.page?
          hsql.offset = (expr.count || DEFAULT_RESOURCES_PER_PAGE) * expr.page

        if expr.offset?
          hsql.offset = expr.offset

        if isFinite(expr.offset)
          hsql.offset = expr.offset

        if expr.joins
          hsql.join = lang.mapcat expr.joins, (x)->
            mk_join(plv8, alias, next_alias, x)

        {hsql: hsql, query: expr}

      exports._search_sql = _search_sql


###  Building SQL from search parameters


To build search expressions, we dispatch to
implementation based on searchType

    get_search_module = (searchType)->
      h = SEARCH_TYPES_TABLE[searchType]
      unless h
        throw new Error("Unsupported search type [#{searchType}]}")
      h

    to_hsql = (tbl, expr)->
      forms =
        $param: (left, right)->
          h = get_search_module(left[0].searchType)
          unless h.handle
            throw new Error("Search type does not exports handle fn: [#{left[0].searchType}] #{JSON.stringify(left)}")
          h.handle(tbl, left, right)
      lisp.eval_with(forms, expr)

    exports.to_hsql = to_hsql

    order_hsql = (tbl, params)->
      for metas in params.map((x)-> x[1])
        meta = metas[0]
        searchType = meta.searchType
        if !searchType
          throw new Error("Empty search type", params)
        h = get_search_module(searchType)
        unless h.order_expression
          throw new Error("Search type does not exports order_expression fn: [#{searchType}] #{JSON.stringify(metas)}")
        h.order_expression(tbl, metas)

    is_nested_order = (params)->
      for metas in params.map((x)-> x[1])
        meta = metas[0]
        if ! meta.searchType && meta[0] && meta[0] == '$param'
          meta = meta[1]
        if ! meta.searchType
          throw new Error("Empty search type", params)
        name = meta.name
        if name.split(".").length > 1
          return true
      return false

    nested_table = (params)->
      for metas in params.map((x)-> x[1])
        meta = metas[0]
        if ! meta.searchType && meta[0] && meta[0] == '$param'
          meta = meta[1]
        if ! meta.searchType
          throw new Error("Empty search type", params)
        name = meta.name
        if name.split(".").length > 1
          return name.split(".")[0]

    resource_type = (table_name)->
      if special_resource_types[table_name]
        return special_resource_types[table_name]
      return "'"+table_name+"'"

    build_join_part = (table, nested_table, main_table_alias, nested_table_alias)->
      switch table
        when "appointment"
          return [[['$raw', "#{nested_table} AS #{nested_table_alias}"],['$raw', "#{nested_table_alias}.id = subelem_id"]]]
        when "encounter"
          resource = resource_type(nested_table)
          if resource == "'participant'"
            return [[['$raw', "#{nested_table} AS #{nested_table_alias}"],['$raw', "#{nested_table_alias}.id = subelem_id"]]]
          else
            return [[['$raw', "#{table} AS #{main_table_alias}"], ['$raw', "#{nested_table_alias}.id=split_part((\"#{main_table_alias}\".resource->#{resource}->>'reference'), '/', 2)"]]]

    build_from_part = (table, nested_table, main_table_alias, nested_table_alias)->
      switch table
        when "appointment"
          return ['$raw', "(SELECT split_part((json_array_elements((\"#{table}\".resource->'participant')::json)->'actor'->>'reference')::text, '/', 2)::text as subelem_id, \"#{table}\".* FROM \"#{table}\") AS #{main_table_alias}"]
        when "encounter"
          resource = resource_type(nested_table)
          if resource == "'participant'"
            return ['$raw', "(SELECT split_part((json_array_elements((\"#{table}\".resource->'participant')::json)->'individual'->>'reference')::text, '/', 2)::text as subelem_id, \"#{table}\".* FROM \"#{table}\") AS #{main_table_alias}"]
          else
            return ['$alias', ['$q', "#{nested_table}"], nested_table_alias]

    get_nested_order_query = (expr, main_table_alias, nested_table_alias, table_name)->
      nested_table_name = nested_table(expr.sort)
      if table_name == "appointment"
        {
            select: ":#{main_table_alias}.*",
            from: build_from_part(table_name, nested_table_name, main_table_alias, nested_table_alias),
            join: build_join_part(table_name, nested_table_name, main_table_alias, nested_table_alias),
            where: expr.where
        }
      else if table_name == "encounter"
        {
            select: ":#{main_table_alias}.*",
            from: build_from_part(table_name, nested_table_name, main_table_alias, nested_table_alias),
            join: build_join_part(table_name, nested_table_name, main_table_alias, nested_table_alias),
            where: expr.where
        }


###  Handling chained parameters

This tricky function converts chained parameters into SQL joins.


    mk_join = (plv8, base, next_alias, chained)->
      current_alias = base
      res = for param in chained[1..-2]
        meta = param[1]
        if meta[0].reverse
            joined_resource = meta[0].resourceType
            joined_table = namings.table_name(plv8, joined_resource)
            join_alias = next_alias()
            value = {value: ":'#{meta[0].join}/' || #{current_alias}.id"}

            on_expr = to_hsql(join_alias, ['$param', meta, value])
            current_alias = join_alias
        else
            joined_resource = meta[0].join
            joined_table = namings.table_name(plv8, joined_resource)
            join_alias = next_alias()
            value = {value: ":'#{joined_resource}/' || #{join_alias}.id"}

            on_expr = to_hsql(current_alias, ['$param', meta, value])
            current_alias = join_alias

        [['$alias', ['$q', joined_table], join_alias], on_expr]

      last_param = lang.last(chained)
      last_cond = to_hsql(current_alias, last_param)
      last_join_cond = lang.last(res)[1]

      res[(res.length - 1)][1] = sql.and(last_join_cond, last_cond)
      res


Helper function to  generate aliases for joins:

    mk_alias = ()->
      tbl_cnt = 0
      ()->
        tbl_cnt += 1
        "tbl#{tbl_cnt}"

To  convert search query into counting query
we just strip limit, offset, order and rewrite select clause:

    countize_query = (q)->
      delete q.limit
      delete q.offset
      delete q.order
      q.select = [':count(*) as count']
      q

    get_count = (plv8, honey, query_obj) ->
      if !query_obj.total_method || query_obj.total_method is "exact"
        query_obj.total_method = "exact"

        utils.exec(plv8, countize_query(honey))[0].count
      else if query_obj.total_method is "estimated"
        sql_query= sql(honey)
        query = sql_query[0].replace /\$(\d+)/g, (match, number) ->
            if typeof sql_query[number] is "string"
              return '\''+sql_query[number]+'\''
            else if typeof sql_query[number] isnt 'undefined'
              return sql_query[number]
            else
              return match
        query = query.replace /LIMIT \d+/, ""
        query = query.replace /\'/g, '\'\''
        query = "SELECT count_estimate('#{query}');"
        tmp = plv8.execute(query)
        tmp[0].count_estimate
      else
        throw new Error("Invalid value of totalMethod. only 'exact', 'estimated' and 'no' allowed.")

We cache FHIR meta-data index per connection using plv8 object:

    ensure_index = (plv8)->
      utils.memoize plv8, 'fhirbaseIdx', -> index.new(plv8, meta_db.getter)


## Indexing

`index_parameter(query)` this function create index for parameter,
awaiting query.resourceType and query.name - name of parameter

    expand_parameter = (plv8, query)->
      idx = ensure_index(plv8)
      expr = expand.expand(idx, ['$param', query])
      if expr[0] == '$param'
        expr[1]
      else
        throw new Error("Indexing: not supported #{JSON.stringify(expr)}")

    ensure_handler = (plv8, metas)->
      uniqtypes = lang.uniq(metas.map((x)-> x.searchType))
      if uniqtypes.length > 1
        throw new Error("We do not support such case #{JSON.stringify(uniqtypes)}")

      h = SEARCH_TYPES_TABLE[uniqtypes[0]]

      unless h
        throw new Error("Unsupported search type [#{uniqtypes[0]}] #{JSON.stringify(metas)}")
      unless h.index
        throw new Error("Search type does not exports index [#{uniqtypes[0]}] #{JSON.stringify(metas)}")

      h


    fhir_index_parameter = (plv8, query)->
      metas = expand_parameter(plv8, query)
      h = ensure_handler(plv8, metas)
      idx_infos = h.index(plv8, metas)

      for idx_info in idx_infos
        if pg_meta.index_exists(plv8, idx_info.name)
          {status: 'error', message: "Index #{idx_info.name} already exists"}
        else
          utils.exec(plv8, idx_info.ddl)
          {status: 'ok', message: "Index #{idx_info.name} was created"}

    fhir_index_parameter.plv8_signature = ['json', 'json']
    exports.fhir_index_parameter = fhir_index_parameter

`fhir_index_order(query)` function creates index for parameter sort,
awaiting query.resourceType and query.name - name of parameter

    fhir_index_order = (plv8, query)->
      metas = expand_parameter(plv8, query)
      h = ensure_handler(plv8, metas)
      idx_infos = h.index_order(plv8, metas)

      for idx_info in idx_infos
       if pg_meta.index_exists(plv8, idx_info.name)
         {status: 'error', message: "Index #{idx_info.name} already exists"}
       else
         utils.exec(plv8, idx_info.ddl)
         {status: 'ok', message: "Index #{idx_info.name} was created"}

    fhir_index_order.plv8_signature = ['json', 'json']
    exports.fhir_index_order = fhir_index_order

    fhir_unindex_parameter = (plv8, query)->
      meta = expand_parameter(plv8, query)
      h = ensure_handler(plv8, meta)
      idx_infos = h.index(plv8, meta)
      for idx_info in idx_infos
        if pg_meta.index_exists(plv8, idx_info.name)
          utils.exec(plv8, drop: 'index', name: ":#{idx_info.name}")
          {status: 'ok', message: "Index #{idx_info.name} was dropped"}
        else
          {status: 'error', message: "Index #{idx_info.name} does not exist"}

    fhir_unindex_parameter.plv8_signature = ['json', 'json']
    exports.fhir_unindex_parameter = fhir_unindex_parameter

    fhir_unindex_order = (plv8, query)->
      meta = expand_parameter(plv8, query)
      h = ensure_handler(plv8, meta)
      idx_infos = h.index_order(plv8, meta)
      for idx_info in idx_infos
        if pg_meta.index_exists(plv8, idx_info.name)
          utils.exec(plv8, drop: 'index', name: ":#{idx_info.name}")
          {status: 'ok', message: "Index #{idx_info.name} was dropped"}
        else
          {status: 'error', message: "Index #{idx_info.name} does not exist"}

    fhir_unindex_order.plv8_signature = ['json', 'json']
    exports.fhir_unindex_order = fhir_unindex_order

## Maintains

This function do analyze on resource tables to update pg statistic
args: query.resourceType

    fhir_analyze_storage = (plv8, query)->
      plv8.execute "ANALYZE \"#{query.resourceType.toLowerCase()}\""
      message: "analyzed"

    fhir_analyze_storage.plv8_signature = ['json', 'json']
    exports.fhir_analyze_storage = fhir_analyze_storage

## Debuging fhirbase search

`fhir.search_sql(query)` is debug function, accepting same arguments as `fhir.search`
and returning SQL query string. It could be used
to analyze, what's happening under the hud.

    fhir_search_sql = (plv8, query)->
      idx_db = ensure_index(plv8)
      sql(_search_sql(plv8, idx_db, query).hsql)

    fhir_search_sql.plv8_signature = ['json', 'json']
    exports.fhir_search_sql = fhir_search_sql

    fhir_explain_search = (plv8, query)->
      idx_db = ensure_index(plv8)
      query = sql(_search_sql(plv8, idx_db, query).hsql)
      query[0] = "EXPLAIN ( ANALYZE, FORMAT JSON ) #{query[0]}"
      plv8.execute(query[0], query[1..-1])

    fhir_explain_search.plv8_signature = ['json', 'json']
    exports.fhir_explain_search = fhir_explain_search

## TODO

* `search_analyze`
* caching queries
