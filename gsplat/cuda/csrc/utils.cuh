#ifndef GSPLAT_CUDA_UTILS_H
#define GSPLAT_CUDA_UTILS_H

#include "helpers.cuh"
#include "third_party/glm/glm/glm.hpp"
#include "third_party/glm/glm/gtc/type_ptr.hpp"
#include <cuda.h>
#include <cuda_runtime.h>

// #define FilterSize 0.7071067811865476
// #define FilterInvSquare 1/(FilterSize*FilterSize)
#define FilterInvSquare 2.f

inline __device__ float3 cross_product(
    float3 a, float3 b 
) {
    float3 result;
    result.x = a.y * b.z - a.z * b.y;
    result.y = a.z * b.x - a.x * b.z;
    result.z = a.x * b.y - a.y * b.x;
    return result;
}

inline __device__ glm::mat3 quat_to_rotmat(const glm::vec4 quat) {
    float w = quat[0], x = quat[1], y = quat[2], z = quat[3];
    // normalize
    float inv_norm = rsqrt(x * x + y * y + z * z + w * w);
    x *= inv_norm;
    y *= inv_norm;
    z *= inv_norm;
    w *= inv_norm;
    float x2 = x * x, y2 = y * y, z2 = z * z;
    float xy = x * y, xz = x * z, yz = y * z;
    float wx = w * x, wy = w * y, wz = w * z;
    return glm::mat3((1.f - 2.f * (y2 + z2)), (2.f * (xy + wz)),
                     (2.f * (xz - wy)), // 1st col
                     (2.f * (xy - wz)), (1.f - 2.f * (x2 + z2)),
                     (2.f * (yz + wx)), // 2nd col
                     (2.f * (xz + wy)), (2.f * (yz - wx)),
                     (1.f - 2.f * (x2 + y2)) // 3rd col
    );
}

inline __device__ glm::mat3 scale_to_mat(const glm::vec3 scale, 
                                    const float glob_scale) {
    glm::mat3 S = glm::mat3(1.f);
    S[0][0] = glob_scale * scale.x;
    S[1][1] = glob_scale * scale.y;
    S[2][2] = glob_scale * scale.z;
    return S;
}

inline __device__ void quat_to_rotmat_vjp(const glm::vec4 quat, const glm::mat3 v_R,
                                          glm::vec4 &v_quat) {
    float w = quat[0], x = quat[1], y = quat[2], z = quat[3];
    // normalize
    float inv_norm = rsqrt(x * x + y * y + z * z + w * w);
    x *= inv_norm;
    y *= inv_norm;
    z *= inv_norm;
    w *= inv_norm;
    glm::vec4 v_quat_n = glm::vec4(
        2.f * (x * (v_R[1][2] - v_R[2][1]) + y * (v_R[2][0] - v_R[0][2]) +
               z * (v_R[0][1] - v_R[1][0])),
        2.f * (-2.f * x * (v_R[1][1] + v_R[2][2]) + y * (v_R[0][1] + v_R[1][0]) +
               z * (v_R[0][2] + v_R[2][0]) + w * (v_R[1][2] - v_R[2][1])),
        2.f * (x * (v_R[0][1] + v_R[1][0]) - 2.f * y * (v_R[0][0] + v_R[2][2]) +
               z * (v_R[1][2] + v_R[2][1]) + w * (v_R[2][0] - v_R[0][2])),
        2.f * (x * (v_R[0][2] + v_R[2][0]) + y * (v_R[1][2] + v_R[2][1]) -
               2.f * z * (v_R[0][0] + v_R[1][1]) + w * (v_R[0][1] - v_R[1][0])));

    glm::vec4 quat_n = glm::vec4(w, x, y, z);
    glm::vec4 temp = (v_quat_n - glm::dot(v_quat_n, quat_n) * quat_n) * inv_norm;
    v_quat += (v_quat_n - glm::dot(v_quat_n, quat_n) * quat_n) * inv_norm;

}

inline __device__ void quat_scale_to_covar_preci(const glm::vec4 quat,
                                                 const glm::vec3 scale,
                                                 // optional outputs
                                                 glm::mat3 *covar, glm::mat3 *preci) {
    glm::mat3 R = quat_to_rotmat(quat);
    if (covar != nullptr) {
        // C = R * S * S * Rt
        glm::mat3 S =
            glm::mat3(scale[0], 0.f, 0.f, 0.f, scale[1], 0.f, 0.f, 0.f, scale[2]);
        glm::mat3 M = R * S;
        *covar = M * glm::transpose(M);
    }
    if (preci != nullptr) {
        // P = R * S^-1 * S^-1 * Rt
        glm::mat3 S = glm::mat3(1.0f / scale[0], 0.f, 0.f, 0.f, 1.0f / scale[1], 0.f,
                                0.f, 0.f, 1.0f / scale[2]);
        glm::mat3 M = R * S;
        *preci = M * glm::transpose(M);
    }
}

inline __device__ void quat_scale_to_covar_vjp(
    // fwd inputs
    const glm::vec4 quat, const glm::vec3 scale,
    // precompute
    const glm::mat3 R,
    // grad outputs
    const glm::mat3 v_covar,
    // grad inputs
    glm::vec4 &v_quat, glm::vec3 &v_scale) {
    float w = quat[0], x = quat[1], y = quat[2], z = quat[3];
    float sx = scale[0], sy = scale[1], sz = scale[2];

    // M = R * S
    glm::mat3 S = glm::mat3(sx, 0.f, 0.f, 0.f, sy, 0.f, 0.f, 0.f, sz);
    glm::mat3 M = R * S;

    // https://math.stackexchange.com/a/3850121
    // for D = W * X, G = df/dD
    // df/dW = G * XT, df/dX = WT * G
    // so
    // for D = M * Mt,
    // df/dM = df/dM + df/dMt = G * M + (Mt * G)t = G * M + Gt * M
    glm::mat3 v_M = (v_covar + glm::transpose(v_covar)) * M;
    glm::mat3 v_R = v_M * S;

    // grad for (quat, scale) from covar
    quat_to_rotmat_vjp(quat, v_R, v_quat);

    v_scale[0] += R[0][0] * v_M[0][0] + R[0][1] * v_M[0][1] + R[0][2] * v_M[0][2];
    v_scale[1] += R[1][0] * v_M[1][0] + R[1][1] * v_M[1][1] + R[1][2] * v_M[1][2];
    v_scale[2] += R[2][0] * v_M[2][0] + R[2][1] * v_M[2][1] + R[2][2] * v_M[2][2];
}

inline __device__ void quat_scale_to_preci_vjp(
    // fwd inputs
    const glm::vec4 quat, const glm::vec3 scale,
    // precompute
    const glm::mat3 R,
    // grad outputs
    const glm::mat3 v_preci,
    // grad inputs
    glm::vec4 &v_quat, glm::vec3 &v_scale) {
    float w = quat[0], x = quat[1], y = quat[2], z = quat[3];
    float sx = 1.0f / scale[0], sy = 1.0f / scale[1], sz = 1.0f / scale[2];

    // M = R * S
    glm::mat3 S = glm::mat3(sx, 0.f, 0.f, 0.f, sy, 0.f, 0.f, 0.f, sz);
    glm::mat3 M = R * S;

    // https://math.stackexchange.com/a/3850121
    // for D = W * X, G = df/dD
    // df/dW = G * XT, df/dX = WT * G
    // so
    // for D = M * Mt,
    // df/dM = df/dM + df/dMt = G * M + (Mt * G)t = G * M + Gt * M
    glm::mat3 v_M = (v_preci + glm::transpose(v_preci)) * M;
    glm::mat3 v_R = v_M * S;

    // grad for (quat, scale) from preci
    quat_to_rotmat_vjp(quat, v_R, v_quat);

    v_scale[0] +=
        -sx * sx * (R[0][0] * v_M[0][0] + R[0][1] * v_M[0][1] + R[0][2] * v_M[0][2]);
    v_scale[1] +=
        -sy * sy * (R[1][0] * v_M[1][0] + R[1][1] * v_M[1][1] + R[1][2] * v_M[1][2]);
    v_scale[2] +=
        -sz * sz * (R[2][0] * v_M[2][0] + R[2][1] * v_M[2][1] + R[2][2] * v_M[2][2]);
}

inline __device__ void persp_proj(
    // inputs
    const glm::vec3 mean3d, const glm::mat3 cov3d, const float fx, const float fy,
    const float cx, const float cy, const uint32_t width, const uint32_t height,
    // outputs
    glm::mat2 &cov2d, glm::vec2 &mean2d) {
    float x = mean3d[0], y = mean3d[1], z = mean3d[2];

    float tan_fovx = 0.5f * width / fx;
    float tan_fovy = 0.5f * height / fy;
    float lim_x = 1.3f * tan_fovx;
    float lim_y = 1.3f * tan_fovy;

    float rz = 1.f / z;
    float rz2 = rz * rz;
    float tx = z * min(lim_x, max(-lim_x, x * rz));
    float ty = z * min(lim_y, max(-lim_y, y * rz));

    // mat3x2 is 3 columns x 2 rows.
    glm::mat3x2 J = glm::mat3x2(fx * rz, 0.f,                  // 1st column
                                0.f, fy * rz,                  // 2nd column
                                -fx * tx * rz2, -fy * ty * rz2 // 3rd column
    );
    cov2d = J * cov3d * glm::transpose(J);
    mean2d = glm::vec2({fx * x * rz + cx, fy * y * rz + cy});
}

inline __device__ void persp_proj_vjp(
    // fwd inputs
    const glm::vec3 mean3d, const glm::mat3 cov3d, const float fx, const float fy,
    const float cx, const float cy, const uint32_t width, const uint32_t height,
    // grad outputs
    const glm::mat2 v_cov2d, const glm::vec2 v_mean2d,
    // grad inputs
    glm::vec3 &v_mean3d, glm::mat3 &v_cov3d) {
    float x = mean3d[0], y = mean3d[1], z = mean3d[2];

    float tan_fovx = 0.5f * width / fx;
    float tan_fovy = 0.5f * height / fy;
    float lim_x = 1.3f * tan_fovx;
    float lim_y = 1.3f * tan_fovy;

    float rz = 1.f / z;
    float rz2 = rz * rz;
    float tx = z * min(lim_x, max(-lim_x, x * rz));
    float ty = z * min(lim_y, max(-lim_y, y * rz));

    // mat3x2 is 3 columns x 2 rows.
    glm::mat3x2 J = glm::mat3x2(fx * rz, 0.f,                  // 1st column
                                0.f, fy * rz,                  // 2nd column
                                -fx * tx * rz2, -fy * ty * rz2 // 3rd column
    );

    // cov = J * V * Jt; G = df/dcov = v_cov
    // -> df/dV = Jt * G * J
    // -> df/dJ = G * J * Vt + Gt * J * V
    v_cov3d += glm::transpose(J) * v_cov2d * J;

    // df/dx = fx * rz * df/dpixx
    // df/dy = fy * rz * df/dpixy
    // df/dz = - fx * mean.x * rz2 * df/dpixx - fy * mean.y * rz2 * df/dpixy
    v_mean3d += glm::vec3(fx * rz * v_mean2d[0], fy * rz * v_mean2d[1],
                          -(fx * x * v_mean2d[0] + fy * y * v_mean2d[1]) * rz2);

    // df/dx = -fx * rz2 * df/dJ_02
    // df/dy = -fy * rz2 * df/dJ_12
    // df/dz = -fx * rz2 * df/dJ_00 - fy * rz2 * df/dJ_11
    //         + 2 * fx * tx * rz3 * df/dJ_02 + 2 * fy * ty * rz3
    float rz3 = rz2 * rz;
    glm::mat3x2 v_J =
        v_cov2d * J * glm::transpose(cov3d) + glm::transpose(v_cov2d) * J * cov3d;

    // fov clipping
    if (x * rz <= lim_x && x * rz >= -lim_x) {
        v_mean3d.x += -fx * rz2 * v_J[2][0];
    } else {
        v_mean3d.z += -fx * rz3 * v_J[2][0] * tx;
    }
    if (y * rz <= lim_y && y * rz >= -lim_y) {
        v_mean3d.y += -fy * rz2 * v_J[2][1];
    } else {
        v_mean3d.z += -fy * rz3 * v_J[2][1] * ty;
    }
    v_mean3d.z += -fx * rz2 * v_J[0][0] - fy * rz2 * v_J[1][1] +
                  2.f * fx * tx * rz3 * v_J[2][0] + 2.f * fy * ty * rz3 * v_J[2][1];
}

inline __device__ void pos_world_to_cam(
    // [R, t] is the world-to-camera transformation
    const glm::mat3 R, const glm::vec3 t, const glm::vec3 p, glm::vec3 &p_c) {
    p_c = R * p + t;
}

inline __device__ void pos_world_to_cam_vjp(
    // fwd inputs
    const glm::mat3 R, const glm::vec3 t, const glm::vec3 p,
    // grad outputs
    const glm::vec3 v_p_c,
    // grad inputs
    glm::mat3 &v_R, glm::vec3 &v_t, glm::vec3 &v_p) {
    // for D = W * X, G = df/dD
    // df/dW = G * XT, df/dX = WT * G
    v_R += glm::outerProduct(v_p_c, p);
    v_t += v_p_c;
    v_p += glm::transpose(R) * v_p_c;
}

inline __device__ void covar_world_to_cam(
    // [R, t] is the world-to-camera transformation
    const glm::mat3 R, const glm::mat3 covar, glm::mat3 &covar_c) {
    covar_c = R * covar * glm::transpose(R);
}

inline __device__ void covar_world_to_cam_vjp(
    // fwd inputs
    const glm::mat3 R, const glm::mat3 covar,
    // grad outputs
    const glm::mat3 v_covar_c,
    // grad inputs
    glm::mat3 &v_R, glm::mat3 &v_covar) {
    // for D = W * X * WT, G = df/dD
    // df/dX = WT * G * W
    // df/dW
    // = G * (X * WT)T + ((W * X)T * G)T
    // = G * W * XT + (XT * WT * G)T
    // = G * W * XT + GT * W * X
    v_R +=
        v_covar_c * R * glm::transpose(covar) + glm::transpose(v_covar_c) * R * covar;
    v_covar += glm::transpose(R) * v_covar_c * R;
}

inline __device__ float inverse(const glm::mat2 M, glm::mat2 &Minv) {
    float det = M[0][0] * M[1][1] - M[0][1] * M[1][0];
    if (det <= 0.f) {
        return det;
    }
    float invDet = 1.f / det;
    Minv[0][0] = M[1][1] * invDet;
    Minv[0][1] = -M[0][1] * invDet;
    Minv[1][0] = Minv[0][1];
    Minv[1][1] = M[0][0] * invDet;
    return det;
}

template <class T>
inline __device__ void inverse_vjp(const T Minv, const T v_Minv, T &v_M) {
    // P = M^-1
    // df/dM = -P * df/dP * P
    v_M += -Minv * v_Minv * Minv;
}

inline __device__ float add_blur(const float eps2d, glm::mat2 &covar,
                                 float &compensation) {
    float det_orig = covar[0][0] * covar[1][1] - covar[0][1] * covar[1][0];
    covar[0][0] += eps2d;
    covar[1][1] += eps2d;
    float det_blur = covar[0][0] * covar[1][1] - covar[0][1] * covar[1][0];
    compensation = sqrt(max(0.f, det_orig / det_blur));
    return det_blur;
}

inline __device__ void add_blur_vjp(const float eps2d, const glm::mat2 conic_blur,
                                    const float compensation,
                                    const float v_compensation, glm::mat2 &v_covar) {
    // comp = sqrt(det(covar) / det(covar_blur))

    // d [det(M)] / d M = adj(M)
    // d [det(M + aI)] / d M  = adj(M + aI) = adj(M) + a * I
    // d [det(M) / det(M + aI)] / d M
    // = (det(M + aI) * adj(M) - det(M) * adj(M + aI)) / (det(M + aI))^2
    // = adj(M) / det(M + aI) - adj(M + aI) / det(M + aI) * comp^2
    // = (adj(M) - adj(M + aI) * comp^2) / det(M + aI)
    // given that adj(M + aI) = adj(M) + a * I
    // = (adj(M + aI) - aI - adj(M + aI) * comp^2) / det(M + aI)
    // given that adj(M) / det(M) = inv(M)
    // = (1 - comp^2) * inv(M + aI) - aI / det(M + aI)
    // given det(inv(M)) = 1 / det(M)
    // = (1 - comp^2) * inv(M + aI) - aI * det(inv(M + aI))
    // = (1 - comp^2) * conic_blur - aI * det(conic_blur)

    float det_conic_blur =
        conic_blur[0][0] * conic_blur[1][1] - conic_blur[0][1] * conic_blur[1][0];
    float v_sqr_comp = v_compensation * 0.5 / (compensation + 1e-6);
    float one_minus_sqr_comp = 1 - compensation * compensation;
    v_covar[0][0] +=
        v_sqr_comp * (one_minus_sqr_comp * conic_blur[0][0] - eps2d * det_conic_blur);
    v_covar[0][1] += v_sqr_comp * (one_minus_sqr_comp * conic_blur[0][1]);
    v_covar[1][0] += v_sqr_comp * (one_minus_sqr_comp * conic_blur[1][0]);
    v_covar[1][1] +=
        v_sqr_comp * (one_minus_sqr_comp * conic_blur[1][1] - eps2d * det_conic_blur);
}

inline __device__ void compute_aabb_vjp(const glm::mat3 M, const glm::vec3 v_mean2D,
                                        glm::mat3 &v_ray_transformation) {
    // glm::mat3 M = glm::mat3(
    //     ray_transformation[0], ray_transformation[1], ray_transformation[2],
    //     ray_transformation[3], ray_transformation[4], ray_transformation[5],
    //     ray_transformation[6], ray_transformation[7], ray_transformation[8]
    // );

    float distance = glm::dot(glm::vec3(1.f, 1.f, -1.f), M[2] * M[2]);
    glm::vec3 temp_point = glm::vec3(1.f, 1.f, -1.f);
    glm::vec3 f = (1.f / distance) * temp_point;

    glm::vec3 p = glm::vec3(
        glm::dot(f, M[0] * M[2]),
        glm::dot(f, M[1] * M[2]),
        glm::dot(f, M[2] * M[2])
    );

    glm::vec3 v_T0 = v_mean2D.x * f * M[2];
    glm::vec3 v_T1 = v_mean2D.y * f * M[2];
    glm::vec3 v_T3 = v_mean2D.x * f * M[0] + v_mean2D.y * f * M[1];
    glm::vec3 v_f = (v_mean2D.x * M[0] * M[2]) + (v_mean2D.y * M[1] * M[2]);
    float v_distance = glm::dot(v_f, f) * (-1.0 / distance);
    glm::vec3 v_d_dT3 = glm::vec3(1.0, 1.0, -1.0) * M[2] * 2.0f;
    v_T3 += v_distance * v_d_dT3;
    // printf("not print: %.2f, %.2f, %.2f\n", v_T0.x, v_T0.y, v_T0.z);
    v_ray_transformation[0][0] += v_T0.x;
    v_ray_transformation[0][1] += v_T0.y;
    v_ray_transformation[0][2] += v_T0.z;
    v_ray_transformation[1][0] += v_T1.x;
    v_ray_transformation[1][1] += v_T1.y;
    v_ray_transformation[1][2] += v_T1.z;
    v_ray_transformation[2][0] += v_T3.x;
    v_ray_transformation[2][1] += v_T3.y;
    v_ray_transformation[2][2] += v_T3.z;
}

inline __device__ void compute_ray_transformation_vjp(const glm::mat3x4 W, const glm::mat3 P,
                                                        const glm::vec3 cam_pos, const glm::vec3 mean,
                                                        const glm::vec4 quat, const glm::vec3 scale, 
                                                        const glm::mat3 v_ray_transformation, const glm::vec3 v_normal3d,
                                                        glm::mat3& v_R, glm::vec2& v_scale, 
                                                        glm::vec3& v_mean3D) {
    glm::vec3 scale_2dgs = glm::vec3(scale.x, scale.y, 1.f);
    glm::mat3 S = scale_to_mat(scale_2dgs, 1.f);
    glm::mat3 R = quat_to_rotmat(quat);
    glm::mat3 RS = R * S;

    glm::mat3 v_M_aug = glm::transpose(P) * glm::transpose(v_ray_transformation);
    glm::mat3 v_M = glm::mat3(
        glm::vec3(v_M_aug[0]),
        glm::vec3(v_M_aug[1]),
        glm::vec3(v_M_aug[2])
    );

    glm::mat3 W_t = glm::transpose(W);
    glm::mat3 v_RS = W_t * v_M;
    glm::vec3 v_RS0 = v_RS[0];
    glm::vec3 v_RS1 = v_RS[1];
    glm::vec3 v_tn = W_t * v_normal3d;

    // dual visible
    glm::vec3 tn = W * R[2];
    float cos = glm::dot(-tn, mean);
    float multiplier = cos > 0 ? 1 : -1;
    v_tn *= multiplier;
    // v_R = glm::mat3(
    //     v_RS0 * glm::vec3(scale[0]),
    //     v_RS1 * glm::vec3(scale[1]),
    //     v_tn
    // );
    // printf("%.2f, %.2f, %.2f\n", v_tn.x, v_tn.y, v_tn.z);
    v_R[0] += v_RS0 * glm::vec3(scale_2dgs[0]);
    v_R[1] += v_RS1 * glm::vec3(scale_2dgs[1]);
    v_R[2] += v_tn;

    // printf("%.9f \n", v_RS1);
    // printf("v_R[0]: %.2f \n", v_RS0 * glm::vec3(scale[0]));
    // printf("v_R: %.2f, %.2f, %.2f \n, %.2f, %.2f, %.2f \n, %.2f, %.2f, %.2f\n", 
    //         v_R[0][0], v_R[0][1], v_R[0][2],
    //         v_R[1][0], v_R[1][1], v_R[1][2],
    //         v_R[2][0], v_R[2][1], v_R[2][2]);

    // v_scale = glm::vec2(
    //     (float)glm::dot(v_RS0, R[0]),
    //     (float)glm::dot(v_RS1, R[1])
    // );

    v_scale[0] += (float)glm::dot(v_RS0, R[0]);
    v_scale[1] += (float)glm::dot(v_RS1, R[1]);
    
    v_mean3D += v_RS[2];
}

#endif // GSPLAT_CUDA_UTILS_H