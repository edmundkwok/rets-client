### jshint node:true ###
### jshint -W097 ###
'use strict'

expat = require('node-expat')
through2 = require('through2')

errors = require('./errors')
replyCodes = require('./replyCodes')
hex2a = require('./hex2a')


# Parsing as performed here and in the other modules of this project relies on some simplifying assumptions.  DO NOT
# COPY OR MODIFY THIS LOGIC BLINDLY!  It works correctly for well-formed XML which adheres to the RETS specifications,
# and does not attempt to check for or properly handle XML not of that form.  In particular, it does not keep track of
# the element stack to ensure elements (and text) are found only in the expected locations.


# a parser with some basic common functionality, intended to be extended for real use
getSimpleParser = (errCallback) ->
  result =
    currElementName: null
    parser: new expat.Parser('UTF-8')
    finish: () ->
      result.parser.removeAllListeners()
    status: null

  result.parser.once 'startElement', (name, attrs) ->
    if name != 'RETS'
      result.finish()
      return errCallback(new Error('Unexpected results. Please check the RETS URL.'))

  result.parser.on 'startElement', (name, attrs) ->
    result.currElementName = name
    if name != 'RETS' && name != 'RETS-STATUS'
      return
    result.status = attrs
    if attrs.ReplyCode != '0' && attrs.ReplyCode != '20208'
      result.finish()
      return errCallback(new errors.RetsReplyError(attrs.ReplyCode, attrs.ReplyText))

  result.parser.on 'error', (err) ->
    result.finish()
    errCallback(new Error("XML parsing error: #{err}"))

  result.parser.on 'end', () ->
    result.finish()
    errCallback(new Error("Unexpected end of xml stream."))

  return result


# parser that deals with column/data tags, as returned for metadata and search queries
getStreamParser = (metadataTag, rawData) ->
  if metadataTag
    rawData = false
    result =
      rowsReceived: 0
      entriesReceived: 0
    delimiter = '\t'
  else
    result =
      rowsReceived: 0
      maxRowsExceeded: false
    delimiter = null
  columnText = null
  dataText = null
  columns = null
  currElementName = null

  parser = new expat.Parser('UTF-8')
  retsStream = through2.obj()
  finish = (type, payload) ->
    parser.removeAllListeners()
    # ignore errors after this point
    parser.on('error', () -> ### noop ###)
    retsStream.write(type: type, payload: payload)
    retsStream.end()
  fail = (err) ->
    finish('error', err)
  writeOutput = (type, payload) ->
    retsStream.write(type: type, payload: payload)
  processStatus = (attrs) ->
    if attrs.ReplyCode != '0' && attrs.ReplyCode != '20208'
      return fail(new errors.RetsReplyError(attrs.ReplyCode, attrs.ReplyText))
    status =
      replyCode: attrs.ReplyCode
      replyTag: replyCodes.tagMap[attrs.ReplyCode]
      replyText: attrs.ReplyText
    writeOutput('status', status)

  parser.once 'startElement', (name, attrs) ->
    if name != 'RETS'
      return fail(new Error('Unexpected results. Please check the RETS URL.'))
    processStatus(attrs)
  
    parser.on 'startElement', (name, attrs) ->
      currElementName = name
      switch name
        when 'DATA'
          dataText = ''
        when 'COLUMNS'
          columnText = ''
        when metadataTag
          writeOutput('metadataStart', attrs)
          result.rowsReceived = 0
        when 'COUNT'
          writeOutput('count', parseInt(attrs.Records))
        when 'MAXROWS'
          result.maxRowsExceeded = true
        when 'DELIMITER'
          delimiter = hex2a(attrs.value)
          writeOutput('delimiter', delimiter)
        when 'RETS-STATUS'
          processStatus(attrs)

  parser.on 'text', (text) ->
    switch currElementName
      when 'DATA'
        dataText += text
      when 'COLUMNS'
        columnText += text

  if rawData
    parser.on 'endElement', (name) ->
      currElementName = null
      switch name
        when 'DATA'
          writeOutput('data', dataText)
          result.rowsReceived++
        when 'COLUMNS'
          writeOutput('columns', columnText)
        when 'RETS'
          finish('done', result)
  else
    parser.on 'endElement', (name) ->
      currElementName = null
      switch name
        when 'DATA'
          if !columns
            return fail(new Error('Failed to parse columns'))
          data = dataText.split(delimiter)
          model = {}
          i=1
          while i < columns.length-1
            model[columns[i]] = data[i]
            i++
          writeOutput('data', model)
          result.rowsReceived++
        when 'COLUMNS'
          if !delimiter
            return fail(new Error('Failed to parse delimiter'))
          columns = columnText.split(delimiter)
          writeOutput('columns', columns)
        when metadataTag
          result.entriesReceived++
          writeOutput('metadataEnd', result.rowsReceived)
        when 'RETS'
          if metadataTag
            delete result.rowsReceived
          finish('done', result)

  parser.on 'error', (err) ->
    fail(new Error("XML parsing error: #{err.stack}"))
  
  parser.on 'end', () ->
    # we remove event listeners upon success, so getting here implies failure
    fail(new Error("Unexpected end of xml stream."))
  
  parser: parser
  fail: fail
  retsStream: retsStream
  
  
module.exports =
  getSimpleParser: getSimpleParser
  getStreamParser: getStreamParser
