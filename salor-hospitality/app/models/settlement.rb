# coding: UTF-8

# Copyright (c) 2012 Red (E) Tools Ltd.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

class Settlement < ActiveRecord::Base
  include Scope
  belongs_to :company
  belongs_to :vendor
  belongs_to :user
  has_many :orders
  has_many :items
  has_many :tax_items
  has_many :payment_method_items

  def finish
    orders = Order.where(:vendor_id => self.vendor_id, :company_id => self.company_id, :settlement_id => nil, :user_id => self.user_id, :finished => true)
    
    order_ids = orders.collect {|o| o.id}
    
    orders.update_all(:settlement_id => self.id)
    
    Item.where(:vendor_id => self.vendor_id, :company_id => self.company_id, :settlement_id => nil, :order_id => order_ids).update_all(:settlement_id => self.id)
    
    TaxItem.where(:vendor_id => self.vendor_id, :company_id => self.company_id, :settlement_id => nil, :order_id => order_ids).update_all(:settlement_id => self.id)
    
    PaymentMethodItem.where(:vendor_id => self.vendor_id, :company_id => self.company_id, :settlement_id => nil, :order_id => order_ids).update_all(:settlement_id => self.id)
    
    self.calculate_totals
  end
  
  def calculate_totals
    self.sum = Order.where(:settlement_id => self.id).sum(:sum).round(2)
    self.save
  end

  def revenue=(revenue)
    write_attribute(:revenue, revenue.gsub(',', '.'))
  end

  def initial_cash=(initial_cash)
    write_attribute(:initial_cash, initial_cash.gsub(',', '.'))
  end

  def print
    vendor_printer = self.vendor.vendor_printers.existing.first
    printr = Printr.new(self.company.mode, vendor_printer)
    printr.open
    printr.print vendor_printer.id, self.escpos
    printr.close
  end

  def calculate_totals
    self.update_attribute :sum, self.orders.sum(:sum)
  end

  def escpos
    vendor = self.vendor
    
    friendly_unit = I18n.t('number.currency.format.friendly_unit', :locale => SalorHospitality::Application::COUNTRIES_REGIONS[vendor.country])
    
    total_payment_methods = {}
    total_payment_methods_refund = {}
    total_costcenter = {}
    
    costcenters = self.vendor.cost_centers.existing.active
    costcenters.each do |cc|
      total_costcenter[cc.id] = 0 #initialize
    end
    total_costcenter[0] = 0 # for orders without costcenter
    
    list_of_orders = ''
    self.orders.existing.each do |o|
      
      cid = o.cost_center_id ? o.cost_center_id : 0
      total_costcenter[cid] += o.sum
      
      t = I18n.l(o.created_at, :format => :time_short)
      costcentername = o.cost_center.name if o.cost_center
      nr = o.nr ? o.nr : 0 # failsafe
      list_of_orders += "\n#%07i %7.7s %10.10s  %5.5s  %6.2f" % [nr, o.table.name, costcentername, t, o.sum]

      o.payment_method_items.each do |pmi|
        if pmi.refunded
          if total_payment_methods_refund.has_key? pmi.payment_method_id
            total_payment_methods_refund[pmi.payment_method_id][:amount] += pmi.amount
          else
            total_payment_methods_refund[pmi.payment_method_id] = {:amount => pmi.amount, :name => "#{ I18n.t(:refund)} #{pmi.payment_method.name}"}
          end
        else
          if total_payment_methods.has_key? pmi.payment_method_id
            total_payment_methods[pmi.payment_method_id][:amount] += pmi.amount
          else
            total_payment_methods[pmi.payment_method_id] = {:amount => pmi.amount, :name => "#{pmi.payment_method.name}"}
          end
        end
      end      
    end
    
    list_of_payment_methods = ''
    total_payment_methods.each do |id,amount|
      list_of_payment_methods += "%s:  #{ friendly_unit } %9.2f\n" % [total_payment_methods[id][:name], total_payment_methods[id][:amount]] unless total_payment_methods[id][:amount].zero?
    end

    list_of_payment_methods_refund = ''
    total_payment_methods_refund.each do |id,amount|
      list_of_payment_methods_refund += "%s:  #{ friendly_unit } %9.2f\n" % [total_payment_methods_refund[id][:name], total_payment_methods_refund[id][:amount]] unless total_payment_methods_refund[id][:amount].zero?
    end
    
    list_of_costcenters = ''
    list_of_costcenters += "     #{ friendly_unit } %9.2f\n" % [total_costcenter[0]] unless total_costcenter[0].zero?
    costcenters.each do |cc|
      list_of_costcenters += "%s:  #{ friendly_unit } %9.2f\n" % [cc.name, total_costcenter[cc.id]] unless total_costcenter[cc.id].zero?
    end
    
    initial_cash = self.initial_cash ? "\n#{ I18n.t 'various.begin' }:  #{ friendly_unit } %9.2f\n" % [self.initial_cash] : ''
    revenue = self.revenue ? "#{ I18n.t 'various.end' }:  #{ friendly_unit } %9.2f\n" % [self.revenue] : ''
    
    output =
    "\e@"     +  # Initialize Printer
    "\ea\x00" +  # align left
    "\e!\x38" +  # doube tall, double wide, bold
    "#{ I18n.t('activerecord.models.settlement.one') } ##{ self.id }\n#{ self.user.login }\n\n"    +
    "\e!\x00" +  # Font A
    "%-10.10s %s\n" % [I18n.t('various.begin'), I18n.l(self.created_at, :format => :datetime_iso)] +
    "%-10.10s %s\n" % [I18n.t('various.end'), I18n.l(self.updated_at, :format => :datetime_iso)] +
    "\n#%7.7s %7.7s  %10.10s %5.5s  %5.5s\n" % [Order.human_attribute_name(:nr), I18n.t('activerecord.models.table.one'), I18n.t('activerecord.models.cost_center.one'), I18n.t('various.time'),  I18n.t(:sum)]+
    list_of_orders +
    "\n" +
    "\e!\x18" +  # double tall, bold
    "\ea\x02" +  # align right
    "%s:  #{ friendly_unit } %9.2f\n" % [I18n.t(:sum), self.sum] +
    "\xc4" * 42 + "\n" +
    list_of_costcenters +
    "\xc4" * 42 + "\n" +
    list_of_payment_methods +
    list_of_payment_methods_refund +
    "\xc4" * 42 + "\n" +
    initial_cash +
    revenue +
    "\xc4" * 42 + "\n" +
    "\e!\x01" + # Font A
    "\n\n\n\n\n" +
    "\x1DV\x00" # paper cut

    Printr.sanitize(output)
  end

end
