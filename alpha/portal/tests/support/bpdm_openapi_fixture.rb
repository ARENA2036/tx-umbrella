# frozen_string_literal: true

# Springdoc-style OpenAPI documents modelled on eclipse-tractusx/bpdm v7.5.0 (tag d68601e7): the /v6 operations the
# pinned Portal backend calls and their schemas (gate: BusinessPartnerInputRequest, PostSharingStateReadyRequest,
# v6 BusinessPartnerOutputDto/SharingStateDto; pool: CxMembershipUpdateRequestV6/CxMembershipDtoV6,
# LegalEntityWithLegalAddressVerboseDtoV6). Only the properties relevant to the checks are modelled; nullable
# references use springdoc's oneOf [$ref, {type: null}] form (e.g. PhysicalPostalAddressDto.street).
module BpdmOpenApiFixture
  module_function

  def r(name)
    { '$ref' => "#/components/schemas/#{name}" }
  end

  def obj(*names, **typed)
    props = names.map { |n| [n.to_s, { 'type' => 'string' }] }.to_h
    typed.each { |k, v| props[k.to_s] = v }
    { 'type' => 'object', 'properties' => props }
  end

  def arr(item)
    { 'type' => 'array', 'items' => item }
  end

  def json(schema)
    { 'application/json' => { 'schema' => schema } }
  end

  def page(item)
    obj(:totalElements, content: arr(item))
  end

  def gate(prefix = '/v6', drop: nil)
    schemas = {
      'BusinessPartnerInputRequest' => obj(:externalId, :isOwnCompanyData,
                                           nameParts: arr('type' => 'string'), identifiers: arr(r('BusinessPartnerIdentifierDto')),
                                           states: arr(r('BusinessPartnerStateDto')), roles: arr('type' => 'string'),
                                           legalEntity: r('LegalEntityRepresentationInputDto'), address: r('AddressRepresentationInputDto')),
      'BusinessPartnerIdentifierDto' => obj(:type, :value, :issuingBody),
      'BusinessPartnerStateDto' => obj(:validFrom, :validTo, :type),
      'LegalEntityRepresentationInputDto' => obj(:legalEntityBpn, :legalName, :shortName, :legalForm),
      'AddressRepresentationInputDto' => obj(:addressBpn, :name, physicalPostalAddress: r('PhysicalPostalAddressDto')),
      'PhysicalPostalAddressDto' => { 'allOf' => [obj(:country, :postalCode, :city), obj(:district, street: { 'oneOf' => [r('StreetDto'), { 'type' => 'null' }] })] },
      'StreetDto' => obj(:name, :houseNumber),
      'PostSharingStateReadyRequest' => obj(externalIds: arr('type' => 'string')),
      'PageDtoBusinessPartnerOutputDto' => page(r('BusinessPartnerOutputDto')),
      'BusinessPartnerOutputDto' => obj(:externalId, legalEntity: obj(:legalEntityBpn), address: obj(:addressBpn)),
      'PageDtoSharingStateDto' => page(obj(:externalId, :sharingStateType, :sharingErrorCode, :sharingErrorMessage, :sharingProcessStarted))
    }
    schemas['StreetDto'] = obj(:houseNumber) if drop == :street_name
    {
      'info' => { 'title' => 'Business Partner Data Management Gate', 'version' => '7.5.0' },
      'paths' => {
        "#{prefix}/input/business-partners" => { 'put' => { 'requestBody' => { 'content' => json(arr(r('BusinessPartnerInputRequest'))) },
                                                            'responses' => { '200' => { 'content' => json(arr(obj(:externalId))) } } } },
        "#{prefix}/sharing-state/ready" => { 'post' => { 'requestBody' => { 'content' => json(r('PostSharingStateReadyRequest')) },
                                                       'responses' => { '204' => { 'description' => 'ok' } } } },
        "#{prefix}/output/business-partners/search" => { 'post' => { 'requestBody' => { 'content' => json(arr('type' => 'string')) },
                                                                   'responses' => { '200' => { 'content' => { '*/*' => { 'schema' => r('PageDtoBusinessPartnerOutputDto') } } } } } },
        "#{prefix}/sharing-state" => { 'get' => { 'responses' => { '200' => { 'content' => json(r('PageDtoSharingStateDto')) } } } }
      },
      'components' => { 'schemas' => schemas }
    }
  end

  # member_field: 'isCatenaXMember' is upstream v7.5.0; 'isArenaXMember' is what the ARENA2036 backend sends.
  def pool(prefix = '/v6', member_field: 'isCatenaXMember')
    {
      'info' => { 'title' => 'Business Partner Data Management Pool', 'version' => '7.5.0' },
      'paths' => {
        "#{prefix}/cx-memberships" => { 'put' => { 'requestBody' => { 'content' => json(r('CxMembershipUpdateRequestV6')) },
                                                  'responses' => { '200' => { 'description' => 'ok' } } } },
        "#{prefix}/legal-entities/{idValue}" => { 'get' => { 'responses' => { '200' => { 'content' => json(r('LegalEntityWithLegalAddressVerboseDtoV6')) } } } }
      },
      'components' => { 'schemas' => {
        'CxMembershipUpdateRequestV6' => obj(memberships: arr(r('CxMembershipDtoV6'))),
        'CxMembershipDtoV6' => obj(:bpnL, member_field.to_sym),
        'LegalEntityWithLegalAddressVerboseDtoV6' => obj(:bpnl, :legalName, identifiers: arr(obj(:value)), states: arr(obj(:validFrom)),
                                                                             legalAddress: obj(:bpna))
      } }
    }
  end
end
