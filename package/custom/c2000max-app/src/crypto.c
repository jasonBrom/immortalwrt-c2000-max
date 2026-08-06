/*
 * Clean-room compatibility helper for the C2000-MAX APP wire formats.
 *
 * The current official APP uses DES-ECB, PKCS#7 padding, Base64 transport and
 * the fixed eight-byte key "96784c1f". Older firmware/APP combinations use
 * AES-256-CBC with a fixed IV and optional per-device or random keys. Keep both
 * formats so upgrades do not break an older installed APP.
 *
 * The token command calculates MD5(request-auth-fields || app-secret).
 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include <errno.h>
#include <openssl/des.h>
#include <openssl/evp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define APP_MAX_INPUT (256U * 1024U)

static const unsigned char default_app_key[32] =
	"383a537d1f2df8c5a76e2f95ddae6a92";
static const unsigned char current_des_key[8] = "96784c1f";
static const unsigned char app_iv[16] = {
	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
	0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
};

static unsigned char *read_stdin(size_t *length)
{
	unsigned char *buf = malloc(APP_MAX_INPUT + 2U);
	size_t used = 0;

	if (!buf)
		return NULL;

	while (used < APP_MAX_INPUT) {
		size_t got = fread(buf + used, 1, APP_MAX_INPUT - used, stdin);
		if (got > APP_MAX_INPUT - used) {
			free(buf);
			errno = EOVERFLOW;
			return NULL;
		}
		used += got;
		if (got == 0) {
			if (ferror(stdin)) {
				free(buf);
				return NULL;
			}
			break;
		}
	}

	if (used == APP_MAX_INPUT && fgetc(stdin) != EOF) {
		free(buf);
		errno = EFBIG;
		return NULL;
	}

	buf[used] = '\0';
	*length = used;
	return buf;
}

static int write_base64(const unsigned char *input, size_t input_len)
{
	unsigned char *encoded;
	size_t encoded_cap;
	int encoded_len;
	int rc = 1;

	if (input_len > INT32_MAX)
		return 1;
	encoded_cap = 4U * ((input_len + 2U) / 3U) + 2U;
	encoded = malloc(encoded_cap);
	if (!encoded)
		return 1;
	encoded_len = EVP_EncodeBlock(encoded, input, (int)input_len);
	if (encoded_len >= 0 &&
	    fwrite(encoded, 1, (size_t)encoded_len, stdout) ==
		    (size_t)encoded_len &&
	    fputc('\n', stdout) != EOF)
		rc = 0;
	free(encoded);
	return rc;
}

static unsigned char *decode_base64(unsigned char *input, size_t input_len,
				    size_t *output_len)
{
	unsigned char *decoded;
	size_t clean_len = 0, index;
	int decoded_len, padding = 0;

	for (index = 0; index < input_len; index++) {
		unsigned char c = input[index];
		if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
			input[clean_len++] = c;
	}
	if (clean_len == 0 || (clean_len % 4U) != 0U ||
	    clean_len > INT32_MAX)
		return NULL;

	decoded = malloc((clean_len / 4U) * 3U + 1U);
	if (!decoded)
		return NULL;
	decoded_len = EVP_DecodeBlock(decoded, input, (int)clean_len);
	if (decoded_len < 0) {
		free(decoded);
		return NULL;
	}
	if (input[clean_len - 1U] == '=')
		padding++;
	if (clean_len >= 2U && input[clean_len - 2U] == '=')
		padding++;
	decoded_len -= padding;
	if (decoded_len <= 0) {
		free(decoded);
		return NULL;
	}
	*output_len = (size_t)decoded_len;
	return decoded;
}

static int encrypt_des(const unsigned char *input, size_t input_len)
{
	DES_cblock key;
	DES_key_schedule schedule;
	unsigned char *padded = NULL;
	unsigned char *cipher = NULL;
	size_t padded_len, offset;
	unsigned char padding;
	int rc = 1;

	if (input_len > APP_MAX_INPUT)
		return 1;
	padding = (unsigned char)(8U - (input_len % 8U));
	padded_len = input_len + padding;
	padded = malloc(padded_len);
	cipher = malloc(padded_len);
	if (!padded || !cipher)
		goto out;

	memcpy(padded, input, input_len);
	memset(padded + input_len, padding, padding);
	memcpy(key, current_des_key, sizeof(key));
	DES_set_key_unchecked(&key, &schedule);

	for (offset = 0; offset < padded_len; offset += 8U) {
		DES_cblock in_block, out_block;
		memcpy(in_block, padded + offset, sizeof(in_block));
		DES_ecb_encrypt(&in_block, &out_block, &schedule, DES_ENCRYPT);
		memcpy(cipher + offset, out_block, sizeof(out_block));
	}
	rc = write_base64(cipher, padded_len);
out:
	free(padded);
	free(cipher);
	return rc;
}

static int decrypt_des(unsigned char *input, size_t input_len)
{
	DES_cblock key;
	DES_key_schedule schedule;
	unsigned char *decoded = NULL;
	unsigned char *plain = NULL;
	size_t decoded_len = 0, plain_len, offset, index;
	unsigned char padding;
	int rc = 1;

	decoded = decode_base64(input, input_len, &decoded_len);
	if (!decoded || (decoded_len % 8U) != 0U ||
	    decoded_len > APP_MAX_INPUT + 8U)
		goto out;
	plain = malloc(decoded_len + 1U);
	if (!plain)
		goto out;

	memcpy(key, current_des_key, sizeof(key));
	DES_set_key_unchecked(&key, &schedule);
	for (offset = 0; offset < decoded_len; offset += 8U) {
		DES_cblock in_block, out_block;
		memcpy(in_block, decoded + offset, sizeof(in_block));
		DES_ecb_encrypt(&in_block, &out_block, &schedule, DES_DECRYPT);
		memcpy(plain + offset, out_block, sizeof(out_block));
	}

	padding = plain[decoded_len - 1U];
	if (padding == 0U || padding > 8U || padding > decoded_len)
		goto out;
	for (index = decoded_len - padding; index < decoded_len; index++) {
		if (plain[index] != padding)
			goto out;
	}
	plain_len = decoded_len - padding;
	if (fwrite(plain, 1, plain_len, stdout) == plain_len)
		rc = 0;
out:
	free(decoded);
	free(plain);
	return rc;
}

static int encrypt_data(const unsigned char *input, size_t input_len,
			const unsigned char key[32])
{
	EVP_CIPHER_CTX *ctx = NULL;
	unsigned char *cipher = NULL;
	unsigned char *encoded = NULL;
	int out_len = 0, final_len = 0;
	size_t cipher_cap = input_len + EVP_MAX_BLOCK_LENGTH;
	int rc = 1;

	if (input_len > INT32_MAX)
		return 1;

	ctx = EVP_CIPHER_CTX_new();
	cipher = malloc(cipher_cap);
	encoded = malloc(4U * ((cipher_cap + 2U) / 3U) + 2U);
	if (!ctx || !cipher || !encoded)
		goto out;

	if (EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, app_iv) != 1 ||
	    EVP_EncryptUpdate(ctx, cipher, &out_len, input, (int)input_len) != 1 ||
	    EVP_EncryptFinal_ex(ctx, cipher + out_len, &final_len) != 1)
		goto out;

	out_len += final_len;
	final_len = EVP_EncodeBlock(encoded, cipher, out_len);
	if (final_len < 0 ||
	    fwrite(encoded, 1, (size_t)final_len, stdout) != (size_t)final_len ||
	    fputc('\n', stdout) == EOF)
		goto out;

	rc = 0;
out:
	EVP_CIPHER_CTX_free(ctx);
	free(cipher);
	free(encoded);
	return rc;
}

static int decrypt_data(unsigned char *input, size_t input_len,
			const unsigned char key[32])
{
	EVP_CIPHER_CTX *ctx = NULL;
	unsigned char *decoded = NULL;
	unsigned char *plain = NULL;
	size_t clean_len = 0, i;
	int decoded_len, out_len = 0, final_len = 0, padding = 0;
	int rc = 1;

	for (i = 0; i < input_len; i++) {
		unsigned char c = input[i];
		if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
			input[clean_len++] = c;
	}
	if (clean_len == 0 || (clean_len % 4U) != 0U || clean_len > INT32_MAX)
		return 1;

	decoded = malloc((clean_len / 4U) * 3U + 1U);
	plain = malloc((clean_len / 4U) * 3U + EVP_MAX_BLOCK_LENGTH + 1U);
	ctx = EVP_CIPHER_CTX_new();
	if (!decoded || !plain || !ctx)
		goto out;

	decoded_len = EVP_DecodeBlock(decoded, input, (int)clean_len);
	if (decoded_len < 0)
		goto out;
	if (clean_len >= 1U && input[clean_len - 1U] == '=')
		padding++;
	if (clean_len >= 2U && input[clean_len - 2U] == '=')
		padding++;
	decoded_len -= padding;
	if (decoded_len <= 0)
		goto out;

	if (EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, app_iv) != 1 ||
	    EVP_DecryptUpdate(ctx, plain, &out_len, decoded, decoded_len) != 1 ||
	    EVP_DecryptFinal_ex(ctx, plain + out_len, &final_len) != 1)
		goto out;

	out_len += final_len;
	if (fwrite(plain, 1, (size_t)out_len, stdout) != (size_t)out_len)
		goto out;
	rc = 0;
out:
	EVP_CIPHER_CTX_free(ctx);
	free(decoded);
	free(plain);
	return rc;
}

static int generate_token(const unsigned char *input, size_t input_len,
			  const unsigned char *secret, size_t secret_len)
{
	EVP_MD_CTX *ctx = NULL;
	unsigned char digest[EVP_MAX_MD_SIZE];
	unsigned int digest_len = 0;
	size_t index;
	int rc = 1;

	ctx = EVP_MD_CTX_new();
	if (!ctx)
		return 1;
	if (EVP_DigestInit_ex(ctx, EVP_md5(), NULL) != 1 ||
	    EVP_DigestUpdate(ctx, input, input_len) != 1 ||
	    EVP_DigestUpdate(ctx, secret, secret_len) != 1 ||
	    EVP_DigestFinal_ex(ctx, digest, &digest_len) != 1 ||
	    digest_len != 16U)
		goto out;

	for (index = 0; index < digest_len; index++) {
		if (fprintf(stdout, "%02x", digest[index]) != 2)
			goto out;
	}
	if (fputc('\n', stdout) == EOF)
		goto out;
	rc = 0;
out:
	EVP_MD_CTX_free(ctx);
	return rc;
}

int main(int argc, char **argv)
{
	unsigned char *input;
	const unsigned char *key = default_app_key;
	size_t input_len;
	int rc;

	if (argc == 3 && strcmp(argv[1], "token") == 0) {
		size_t secret_len = strlen(argv[2]);
		if (secret_len == 0U || secret_len > 128U) {
			fprintf(stderr, "secret must contain 1 to 128 bytes\n");
			return 2;
		}
		input = read_stdin(&input_len);
		if (!input) {
			fprintf(stderr, "input error\n");
			return 1;
		}
		rc = generate_token(input, input_len,
			(const unsigned char *)argv[2], secret_len);
		free(input);
		return rc;
	}

	if (argc == 2 &&
	    (strcmp(argv[1], "des-encrypt") == 0 ||
	     strcmp(argv[1], "des-decrypt") == 0)) {
		input = read_stdin(&input_len);
		if (!input) {
			fprintf(stderr, "input error\n");
			return 1;
		}
		if (strcmp(argv[1], "des-encrypt") == 0)
			rc = encrypt_des(input, input_len);
		else
			rc = decrypt_des(input, input_len);
		free(input);
		return rc;
	}

	if ((argc != 2 && argc != 3) ||
	    (strcmp(argv[1], "encrypt") != 0 &&
	     strcmp(argv[1], "decrypt") != 0)) {
		fprintf(stderr,
			"usage: %s des-encrypt|des-decrypt | "
			"encrypt|decrypt [32-byte-key] | token secret\n",
			argv[0]);
		return 2;
	}
	if (argc == 3) {
		if (strlen(argv[2]) != 32U) {
			fprintf(stderr, "key must contain exactly 32 bytes\n");
			return 2;
		}
		key = (const unsigned char *)argv[2];
	}

	input = read_stdin(&input_len);
	if (!input) {
		fprintf(stderr, "input error\n");
		return 1;
	}

	if (strcmp(argv[1], "encrypt") == 0)
		rc = encrypt_data(input, input_len, key);
	else
		rc = decrypt_data(input, input_len, key);

	free(input);
	return rc;
}
