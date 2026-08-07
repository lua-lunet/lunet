global record jsonic
    null: any
    decode: function(str: string, position: integer, nullval: any): any, integer, string
    encode: function(value: any, opts: {string: any}): string
end
