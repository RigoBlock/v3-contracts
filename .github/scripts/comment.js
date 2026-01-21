module.exports = async ({ github, context, header, body, prNumber }) => {
  const comment = [header, body].join("\n");

  // Use provided prNumber or fall back to context (for backward compatibility)
  const issueNumber = prNumber || context.payload.number;

  const { data: comments } = await github.rest.issues.listComments({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: issueNumber,
  });

  const botComment = comments.find(
    (comment) =>
      // github-actions bot user
      comment.user.id === 41898282 && comment.body.startsWith(header)
  );

  const commentFn = botComment ? "updateComment" : "createComment";

  await github.rest.issues[commentFn]({
    owner: context.repo.owner,
    repo: context.repo.repo,
    body: comment,
    ...(botComment
      ? { comment_id: botComment.id }
      : { issue_number: issueNumber }),
  });
};