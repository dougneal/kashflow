module Kashflow
  class Client
    attr_reader :service
  
    def self.yaml_path
      File.join(Kashflow.root, 'config', 'kf_api_methods.yml')
    end
  
    def self.api_methods
      @@api_methods ||= YAML.load_file(yaml_path)
    end
  
    def initialize(login, password)
      raise "missing login/password" unless login and password
    
      @login, @password = login, password
      @service = Savon::Client.new do |wsdl, http|
        wsdl.document = "https://securedwebapp.com/api/service.asmx?wsdl"
        http.auth.ssl.verify_mode = :none
      end
    end
  
    def lookup_api_method(name)
      self.class.api_methods.detect{ |api_method| api_method.name.underscore == name.to_s }
    end
  
    def method_missing(m, *args, &block) 
      api_method = lookup_api_method(m)
    
      if api_method
        # puts "found api_method #{api_method.name} for #{m}: #{api_method.request_attrs.inspect}"
        # puts "you're calling with #{args.inspect}"
        
        api_call(m, api_method.name, args)
      else
        raise "method_missing: No method for #{m}"
      end
    end
  
    def api_call(name, method, args)
      soap_return = soap_call(name, method, args)
      response = soap_return["#{name}_response".to_sym]
      # puts "got response: " + response.inspect
    
      raise "API call failed: [#{response[:status_detail]}]\n\n #{response.inspect}" unless response[:status] == 'OK'
    
      r = response["#{name}_result".to_sym]
      if r.is_a?(String)
          r
      else
        if r.is_a?(Enumerable)
          if r.values.all?{|v| v.is_a?(Array) }# || r.keys.size == 1
            object_type, attrs = r.first
          else
            # puts "arrayifying #{r.inspect}"
            object_type = lookup_api_method(name).response_attrs.first[:type]
            attrs = r.first.last.is_a?(Hash) ? [r.first.last] : [r]
          end
              
          # puts "it's an enumerable... #{object_type} | #{attrs.inspect}"
              
          ostructs = attrs.map do |record_attrs|
            # puts "making new ostruct with #{record_attrs.inspect}"
            OpenStruct.new(record_attrs.merge(:object_type => object_type.to_s))
          end
        else
          r
        end
      end
    end
   
    def object_wrapper(name, params_xml)
      operation, object = name.to_s.split('_', 2)

      # Aliases differ depending on whether we're inserting or updating; thanks Kashflow
      xml_tags = {
        'insert' => {
          'customer'        => 'custr',
          'quote'           => 'quote',
          'invoice'         => 'Inv',
          'supplier'        => 'supl',
          'receipt'         => 'Inv',
          'invoice_line'    => 'InvLine',
          'invoice_payment' => 'InvoicePayment',
          'receipt_payment' => 'ReceiptPayment'
        },
        'update' => {
          'customer' => 'custr',
          'quote'    => 'quote',
          'invoice'  => 'Inv',
          'supplier' => 'sup',
          'receipt'  => 'Receipt',
          'line'     => 'InvLine',
          'payment'  => 'InvoicePayment'
        }
      }
     

      if not ['insert', 'update'].include?(operation) then
        # Yuck - this should really be an exception
        return ["",""]
      end

      xml_tag = xml_tags[operation][object]

      # Not quite sure what this bit is all about, but not my concern right now so leaving as is
      if object =~ /^invoice_line/ then
        if name.to_s == "insert_invoice_line_with_invoice_number" then
          line_id = "<InvoiceNumber>#{params_xml.match(/<InvoiceNumber>(.*?)<\/InvoiceNumber>/)[1]}</InvoiceNumber>\n\t\t"
        else
          line_id = "<ReceiptID>#{params_xml.match(/<ReceiptID>(.*?)<\/ReceiptID>/)[1]}</ReceiptID>\n\t\t" if object == "receipt"
          line_id = "<InvoiceID>#{params_xml.match(/<InvoiceID>(.*?)<\/InvoiceID>/)[1]}</InvoiceID>\n\t\t" if object == "invoice"
        end

        return ["#{line_id}<#{xml_tag}>", "</#{xml_tag}>"]
      end

      return [sprintf("<%s>", xml_tag), sprintf("</%s>", xml_tag)]
    end

    def soap_call(name, method, params = {})
      begin
        result = @service.request(name) do |soap|
       
          params = params.pop if params.is_a?(Array)

          # Our bit
          if params.is_a?(OpenStruct) then
            params_xml = ""

            params.marshal_dump.each do |key, value|
              xml_tag = key.to_s.camelize
              if xml_tag == 'Lines' then
                params_xml << "<Lines>\n"

                [value[:any_type]].flatten.each do |line|
                  params_xml << "<anyType xsi:type=\"InvoiceLine\">\n"
                  line.each do |line_key, line_value|
                    xml_tag = line_key.to_s.camelize
                    params_xml << sprintf("<%s>%s</%s>\n", xml_tag, line_value, xml_tag)
                  end
                  params_xml << '</anyType>'
                end
                
                params_xml << "</Lines>\n"
              else
                params_xml << "<#{xml_tag}>#{value}</#{xml_tag}>\n"
              end
            end

          # Incumbent code
          else
            params_xml = params.map do |field, value|
              xml_tag = field.to_s.camelize
              "<#{xml_tag}>#{value}</#{xml_tag}>"
            end.join("\n") unless params.blank?

          end
          
          params_xml = params_xml.gsub(/Id>/,"ID>") if params_xml
          params_xml = params_xml.gsub(/Dbid>/,"DBID>") if params_xml
          pretext, posttext = object_wrapper(name, params_xml)
          
          soap.xml = %[<?xml version="1.0" encoding="utf-8"?>
          <soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
            <soap:Body>
              <#{method} xmlns="KashFlow">
                <UserName>#{@login}</UserName>
                <Password>#{@password}</Password>
                #{pretext}
                #{params_xml}
                #{posttext}
              </#{method}>
            </soap:Body>
          </soap:Envelope>]
        end.to_hash
      rescue Savon::SOAP::Fault => e
        puts "soap fault:" + e.inspect
        return false
      end
    end

  end
end
