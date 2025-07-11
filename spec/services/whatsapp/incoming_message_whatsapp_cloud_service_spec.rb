require 'rails_helper'

describe Whatsapp::IncomingMessageWhatsappCloudService do
  describe '#perform' do
    let!(:whatsapp_channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
    let(:params) do
      {
        phone_number: whatsapp_channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Sojan Jose' }, wa_id: '2423423243' }],
              messages: [{
                from: '2423423243',
                image: {
                  id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683',
                  mime_type: 'image/jpeg',
                  sha256: '29ed500fa64eb55fc19dc4124acb300e5dcca0f822a301ae99944db',
                  caption: 'Check out my product!'
                },
                timestamp: '1664799904', type: 'image'
              }]
            }
          }]
        }]
      }.with_indifferent_access
    end

    context 'when valid attachment message params' do
      it 'creates appropriate conversations, message and contacts' do
        stub_request(:get, whatsapp_channel.media_url('b1c68f38-8734-4ad3-b4a1-ef0c10d683')).to_return(
          status: 200,
          body: {
            messaging_product: 'whatsapp',
            url: 'https://chatwoot-assets.local/sample.png',
            mime_type: 'image/jpeg',
            sha256: 'sha256',
            file_size: 'SIZE',
            id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683'
          }.to_json,
          headers: { 'content-type' => 'application/json' }
        )
        stub_request(:get, 'https://chatwoot-assets.local/sample.png').to_return(
          status: 200,
          body: File.read('spec/assets/sample.png')
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.first.content).to eq('Check out my product!')
        expect(whatsapp_channel.inbox.messages.first.attachments.present?).to be true
      end

      it 'increments reauthorization count if fetching attachment fails' do
        stub_request(:get, whatsapp_channel.media_url('b1c68f38-8734-4ad3-b4a1-ef0c10d683')).to_return(
          status: 401
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.first.content).to eq('Check out my product!')
        expect(whatsapp_channel.inbox.messages.first.attachments.present?).to be false
        expect(whatsapp_channel.authorization_error_count).to eq(1)
      end
    end

    context 'when invalid attachment message params' do
      let(:error_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Sojan Jose' }, wa_id: '2423423243' }],
                messages: [{
                  from: '2423423243',
                  image: {
                    id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683',
                    mime_type: 'image/jpeg',
                    sha256: '29ed500fa64eb55fc19dc4124acb300e5dcca0f822a301ae99944db',
                    caption: 'Check out my product!'
                  },
                  errors: [{
                    code: 400,
                    details: 'Last error was: ServerThrottle. Http request error: HTTP response code said error. See logs for details',
                    title: 'Media download failed: Not retrying as download is not retriable at this time'
                  }],
                  timestamp: '1664799904', type: 'image'
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'with attachment errors' do
        described_class.new(inbox: whatsapp_channel.inbox, params: error_params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.count).to eq(0)
      end
    end

    context 'when invalid params' do
      it 'will not throw error' do
        described_class.new(inbox: whatsapp_channel.inbox, params: { phone_number: whatsapp_channel.phone_number,
                                                                     object: 'whatsapp_business_account', entry: {} }).perform
        expect(whatsapp_channel.inbox.conversations.count).to eq(0)
        expect(Contact.all.first).to be_nil
        expect(whatsapp_channel.inbox.messages.count).to eq(0)
      end
    end

    context 'when message contains referral data' do
      let(:referral_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Test User' }, wa_id: '1234567890' }],
                messages: [{
                  from: '1234567890',
                  id: 'wamid.referral_message_id',
                  timestamp: '1678886400',
                  type: 'text',
                  text: { body: 'I saw this ad and I am interested!' },
                  referral: {
                    source_url: 'https://fb.me/sample_ad_link',
                    source_id: 'SAMPLE_AD_ID',
                    source_type: 'ad',
                    headline: 'Check out this Great Product!',
                    body: 'Click here to learn more about our amazing product.',
                    media_type: 'image',
                    image_url: 'https://example.com/ad_image.png',
                    video_url: nil,
                    thumbnail_url: 'https://example.com/ad_thumbnail.png',
                    ctwa_clid: 'SAMPLE_CTWA_CLID'
                  }
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'creates message with referral data in additional_attributes and includes it in webhook_data' do
        described_class.new(inbox: whatsapp_channel.inbox, params: referral_params).perform

        expect(whatsapp_channel.inbox.conversations.count).to eq(1)
        expect(whatsapp_channel.inbox.messages.count).to eq(1)

        message = whatsapp_channel.inbox.messages.first
        expect(message).not_to be_nil
        expect(message.content).to eq('I saw this ad and I am interested!')
        expect(message.additional_attributes).not_to be_nil

        ad_referral_data = message.additional_attributes['ad_referral']
        expect(ad_referral_data).not_to be_nil
        expect(ad_referral_data['source_url']).to eq('https://fb.me/sample_ad_link')
        expect(ad_referral_data['source_id']).to eq('SAMPLE_AD_ID')
        expect(ad_referral_data['source_type']).to eq('ad')
        expect(ad_referral_data['headline']).to eq('Check out this Great Product!')
        expect(ad_referral_data['body']).to eq('Click here to learn more about our amazing product.')
        expect(ad_referral_data['media_type']).to eq('image')
        expect(ad_referral_data['image_url']).to eq('https://example.com/ad_image.png')
        expect(ad_referral_data['video_url']).to be_nil
        expect(ad_referral_data['thumbnail_url']).to eq('https://example.com/ad_thumbnail.png')
        expect(ad_referral_data['ctwa_clid']).to eq('SAMPLE_CTWA_CLID')

        # Verify webhook_data
        webhook_additional_attrs = message.webhook_data[:additional_attributes]
        expect(webhook_additional_attrs).not_to be_nil
        webhook_ad_referral_data = webhook_additional_attrs['ad_referral']
        expect(webhook_ad_referral_data).not_to be_nil
        expect(webhook_ad_referral_data['source_url']).to eq('https://fb.me/sample_ad_link')
        expect(webhook_ad_referral_data['source_id']).to eq('SAMPLE_AD_ID')
        expect(webhook_ad_referral_data['headline']).to eq('Check out this Great Product!')
      end
    end
  end
end
