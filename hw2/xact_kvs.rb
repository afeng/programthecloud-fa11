require 'rubygems'
require 'bud'
require 'kvs.rb'
require 'lckmgr.rb'

module XactKVSProtocol
  state do
    interface input, :xput, [:xid, :key, :reqid] => [:data]
    interface input, :xget, [:xid, :key, :reqid]
    interface output, :xget_response, [:xid, :key, :reqid] => [:data]
    interface output, :xput_response, [:xid, :key, :reqid]
  end
end

module XactKVSProtocol
  include XactKVSProtocol
  include TwoPhaseLockMgr
  # FIXME: Not sure if I should be importing or including. Thoughts?
  import BasicKVS => :bkvs

  # Perform the puts
  bloom :mutate do
    request_lock <+ xput {|x| [x.xid, x.key, ":X"]}
    bed.kvput <+ (xput * lock_status).lefts(:xid => :xid, :key => :resource) 
    # Not sure how to populate xput_response

  end

  # Perform the gets
  bloom :get do
    request_lock <+ xget {|x| [x.xid, x.key, ":S"]}
    bed.kvget <+ (xget * lock_status).lefts(:xid => :reqid, :key => :resource)
    xget_response <+ bed.kvget_response {|x| [x.xid, x.key, x.xid, x.value]}
  end
end
