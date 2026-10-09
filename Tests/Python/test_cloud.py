import io
import json
import unittest
from urllib.error import HTTPError
from unity_cloud import Client, CloudError, NoRedirect

class CloudTests(unittest.TestCase):
    def client(self):
        return Client({"UNITY_SERVICE_ACCOUNT_KEY_ID":"test-id-only", "UNITY_SERVICE_ACCOUNT_SECRET_KEY":"test-secret-only"})

    def test_absent_credentials_send_no_request(self):
        with self.assertRaises(CloudError) as error: Client({})
        self.assertEqual(error.exception.report["requests_sent"],0)

    def test_credential_values_and_encoded_header_redacted(self):
        client=self.client()
        output=json.dumps(client.redact({"details":[client.auth,"test-secret-only","test-id-only"]}))
        for secret in client.secrets:self.assertNotIn(secret,output)

    def test_redirect_cannot_forward_authorization(self):
        self.assertIsNone(NoRedirect().redirect_request(None,None,302,"",{},"https://example.invalid"))

    def test_server_permission_error_preserved_without_secret(self):
        client=self.client()
        class Opener:
            def open(self,request,timeout):
                body={"requestId":"test-request", "detail":"missing project read permission; test-secret-only", "code":40301}
                raise HTTPError(request.full_url,403,"Forbidden",{},io.BytesIO(json.dumps(body).encode()))
        client.opener=Opener()
        with self.assertRaises(CloudError) as error:client.call("/test")
        report=error.exception.report
        self.assertEqual(report["status"],403)
        self.assertIn("missing project read permission",report["unity_detail"])
        self.assertNotIn("test-secret-only",json.dumps(report))

    def test_duplicate_project_names_do_not_guess(self):
        client=self.client();client.call=lambda _: [{"name":"Yardman","projectid":"one"},{"name":"Yardman","projectid":"two"}]
        with self.assertRaises(CloudError):client.project()

    def test_project_output_excludes_settings_credentials(self):
        client=self.client();client.call=lambda _: [{"name":"Yardman","projectid":"one","settings":{"scm":{"pass":"test"}}}]
        self.assertEqual(client.project(),{"name":"Yardman","projectid":"one"})

if __name__=="__main__":unittest.main()
